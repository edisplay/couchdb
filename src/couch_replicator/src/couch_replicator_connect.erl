% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

%% This module implements the connect_to configuration option, which allows
%% routing replication requests through proxies or rewriting connection ports.
%% Similar to curl's --connect-to option.
%%
%% Flow:
%% 1. init/0 - Parse and cache connect_to config at startup
%% 2. apply_connect_to/2 - For each replication request:
%%    a. Parse URL to extract host and port
%%    b. resolve_connection/2 - Match host:port against override patterns
%%    c. On match:
%%       - Reconstruct URL with target port
%%       - Add ibrowse connect_to option (target host)
%%       - Add SNI option for HTTPS (original host)
%%    d. Return modified URL and options
%%
%% Configuration format: host:port:target_host:target_port
%% Example: *.example.com:443:proxy.internal:8443
%%
%% Pattern matching:
%% - Exact hostnames: foo.example.com
%% - Leading wildcards: *.example.com (matches sub.example.com, not example.com)
%% - Case-insensitive
%% - Port must match exactly

-module(couch_replicator_connect).

-include_lib("ibrowse/include/ibrowse.hrl").

-export([
    init/0,
    apply_connect_to/2
]).

-ifdef(TEST).
-export([
    parse_config/1,
    match_host_pattern/2,
    get_overrides/0,
    resolve_connection/2,
    parse_ip_address/1
]).
-endif.

-type connect_to_override() :: {
    PatternHost :: binary(),
    PatternPort :: integer(),
    TargetHost :: binary() | inet:ip_address(),
    TargetPort :: integer()
}.

-define(CONNECT_TO_KEY, {?MODULE, connect_to}).

%% Initialize connect_to overrides cache
-spec init() -> ok.
init() ->
    Overrides =
        case config:get("replicator", "connect_to", undefined) of
            undefined -> [];
            ConfigStr -> parse_config(ConfigStr)
        end,
    persistent_term:put(?CONNECT_TO_KEY, Overrides),
    ok.

%% Resolve connection override for a host:port pair.
%% String/binary conversions:
%% - Input: ibrowse provides Host as string
%% - Internal: overrides stored as binaries or tuples (IPs)
%% - Output: ibrowse connect_to option requires string or tuple
-spec resolve_connection(string(), integer()) ->
    {string() | inet:ip_address(), integer(), string()} | not_found.
resolve_connection(Host, Port) ->
    case find_override(list_to_binary(Host), Port, get_overrides()) of
        {ok, {TargetHost, TargetPort}} when is_binary(TargetHost) ->
            {binary_to_list(TargetHost), TargetPort, Host};
        {ok, {TargetHost, TargetPort}} when is_tuple(TargetHost) ->
            {TargetHost, TargetPort, Host};
        not_found ->
            not_found
    end.

-spec get_overrides() -> [connect_to_override()].
get_overrides() ->
    case persistent_term:get(?CONNECT_TO_KEY, not_initialized) of
        not_initialized ->
            % fall back to reading config
            case config:get("replicator", "connect_to", undefined) of
                undefined -> [];
                ConfigStr -> parse_config(ConfigStr)
            end;
        Overrides ->
            Overrides
    end.

-spec parse_config(string()) -> [connect_to_override()].
parse_config(ConfigStr) ->
    ConfigBin = list_to_binary(ConfigStr),
    Entries = binary:split(ConfigBin, <<",">>, [global, trim]),
    lists:filtermap(fun parse_entry/1, Entries).

% Format: HOST:PORT:TARGET:TARGET_PORT (matches curl --connect-to)
% Examples:
%   *.example.com:443:192.168.1.1:8443
%   *.example.com:443:[2001:db8::1]:8443
% IPv6 addresses in targets must be enclosed in brackets
parse_entry(<<>>) ->
    false;
parse_entry(Entry0) ->
    Entry = string:trim(Entry0),
    % Regex: HOST:PORT:TARGET:TARGET_PORT where TARGET can be [IPv6]
    % Reject IPv6 patterns (starting with [), ensure non-empty captures
    Pattern = "^([^:\\[]+):([0-9]+):([^:]+|\\[[^\\]]+\\]):([0-9]+)$",
    case re:run(Entry, Pattern, [{capture, all_but_first, binary}]) of
        {match, [PatternHost, PatternPortBin, TargetHost0, TargetPortBin]} ->
            % Regex guarantees non-empty hosts and numeric ports
            PatternPort = binary_to_integer(PatternPortBin),
            TargetPort = binary_to_integer(TargetPortBin),
            % Convert IP addresses to tuples; keep hostnames as binaries
            TargetHost =
                case parse_ip_address(TargetHost0) of
                    {ok, IpTuple} -> IpTuple;
                    {error, einval} -> TargetHost0
                end,
            {true, {PatternHost, PatternPort, TargetHost, TargetPort}};
        nomatch ->
            couch_log:warning(
                "Invalid connect_to entry: ~ts (expected HOST:PORT:TARGET:TARGET_PORT)", [
                    Entry
                ]
            ),
            false
    end.

-spec find_override(binary(), integer(), [connect_to_override()]) ->
    {ok, {binary() | inet:ip_address(), integer()}} | not_found.
find_override(_Host, _Port, []) ->
    not_found;
% This relies on pattern matching the host Port and the config entry Port,
% before testing the Host against the config entry Pattern
find_override(Host, Port, [{Pattern, Port, Target, TargetPort} | Rest]) ->
    case match_host_pattern(Host, Pattern) of
        true ->
            {ok, {Target, TargetPort}};
        false ->
            find_override(Host, Port, Rest)
    end;
find_override(Host, Port, [_Mismatch | Rest]) ->
    find_override(Host, Port, Rest).

% Host Pattern Matching
%
% Supports leading wildcard patterns only:
%   - *.example.com matches any.subdomain.example.com
%   - *.example.com does NOT match example.com (requires at least one subdomain)
%
% Not supported:
%   - middle wildcards: sub.*.example.com
%   - trailing wildcards: example.*
%   - multiple wildcards: *.*.example.com
-spec match_host_pattern(binary(), binary()) -> boolean().
match_host_pattern(Host, Pattern) when is_binary(Host), is_binary(Pattern) ->
    % DNS names are case-insensitive
    HostLower = string:lowercase(Host),
    PatternLower = string:lowercase(Pattern),
    match_host_pattern_impl(HostLower, PatternLower).

match_host_pattern_impl(Host, <<"*", Suffix/binary>>) ->
    % wildcard match: extract last N bytes from Host and compare to Suffix
    HostSize = byte_size(Host),
    SuffixSize = byte_size(Suffix),
    % ensure we have enough bytes before extracting suffix
    case HostSize >= SuffixSize of
        true ->
            Pos = HostSize - SuffixSize,
            binary:part(Host, Pos, SuffixSize) =:= Suffix;
        false ->
            false
    end;
match_host_pattern_impl(Host, Pattern) ->
    Host =:= Pattern.

%% Parse IP address from string or binary, stripping IPv6 brackets if present.
%% Returns {ok, IpTuple} if valid IP, {error, einval} otherwise.
-spec parse_ip_address(string() | binary()) -> {ok, inet:ip_address()} | {error, einval}.
parse_ip_address(Host) when is_list(Host) ->
    HostStripped = string:trim(Host, both, "[]"),
    case inet:parse_strict_address(HostStripped) of
        {ok, IpTuple} -> {ok, IpTuple};
        {error, _} -> {error, einval}
    end;
parse_ip_address(Host) when is_binary(Host) ->
    parse_ip_address(binary_to_list(Host)).

%% Apply connect_to override to URL and ibrowse options
-spec apply_connect_to(string(), list()) -> {string(), list()}.
apply_connect_to(Url, IbrowseOptions) ->
    case ibrowse_lib:parse_url(Url) of
        {error, _} ->
            {Url, IbrowseOptions};
        #url{host = Host, port = Port, protocol = Protocol} = ParsedUrl ->
            case resolve_connection(Host, Port) of
                {TargetHost, TargetPort, OriginalHost} ->
                    % Reconstruct URL with target port
                    Url2 = reconstruct_url(ParsedUrl, TargetPort),
                    % Apply connection override options
                    Opts = apply_override_options(
                        IbrowseOptions,
                        Protocol,
                        TargetHost,
                        OriginalHost
                    ),
                    {Url2, Opts};
                not_found ->
                    {Url, IbrowseOptions}
            end
    end.

%% Reconstruct URL with new port.
%% Note: ibrowse:send_req_direct requires a string URL, not a parsed #url{} record.
%% The #url.path field from ibrowse_lib:parse_url includes the full path with
%% query string and fragment, so we don't need to handle those separately.
%% Credentials are not included because normalize_basic_auth() strips them from
%% URLs before they reach this code - they're passed via ibrowse options instead.
-spec reconstruct_url(#url{}, integer()) -> string().
reconstruct_url(#url{protocol = Protocol, host = Host, path = Path}, NewPort) ->
    Scheme = atom_to_list(Protocol),
    PortStr = ":" ++ integer_to_list(NewPort),
    Scheme ++ "://" ++ Host ++ PortStr ++ Path.

%% Apply connect_to and SNI options
-spec apply_override_options(list(), atom(), string() | inet:ip_address(), string()) -> list().
apply_override_options(Opts, Protocol, TargetHost, OriginalHost) ->
    couch_log:debug(
        "connect_to override (~p): ~s -> ~p",
        [Protocol, OriginalHost, TargetHost]
    ),
    couch_stats:increment_counter([couch_replicator, connect_to_applied]),
    % Add connect_to option (ibrowse accepts string or tuple)
    Opts1 = [{connect_to, TargetHost} | Opts],
    % Add SNI for HTTPS if OriginalHost is a hostname (not IP)
    SNIHost =
        case {Protocol, parse_ip_address(OriginalHost)} of
            {https, {error, _}} ->
                OriginalHost;
            _ ->
                disable
        end,
    add_sni_option(Opts1, SNIHost).

-spec add_sni_option(list(), string() | disable) -> list().
add_sni_option(IbrowseOpts, Host) ->
    SslOpts = proplists:get_value(ssl_options, IbrowseOpts, []),
    SslOpts1 = [
        {server_name_indication, Host}
        | proplists:delete(server_name_indication, SslOpts)
    ],
    lists:keystore(ssl_options, 1, IbrowseOpts, {ssl_options, SslOpts1}).
