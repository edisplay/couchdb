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

-module(couch_replicator_connect_tests).

-include_lib("couch/include/couch_eunit.hrl").

match_pattern_test_() ->
    [
        % wildcard matching
        ?_assert(
            couch_replicator_connect:match_host_pattern(
                <<"account.example.test">>, <<"*.example.test">>
            )
        ),
        ?_assertNot(
            couch_replicator_connect:match_host_pattern(
                <<"example.test">>, <<"*.example.test">>
            )
        ),
        % exact matching
        ?_assert(
            couch_replicator_connect:match_host_pattern(
                <<"exact.example.test">>, <<"exact.example.test">>
            )
        ),
        ?_assertNot(
            couch_replicator_connect:match_host_pattern(
                <<"other.example.test">>, <<"exact.example.test">>
            )
        ),
        % case insensitive
        ?_assert(
            couch_replicator_connect:match_host_pattern(
                <<"account.example.test">>, <<"*.Example.Test">>
            )
        ),
        ?_assert(
            couch_replicator_connect:match_host_pattern(
                <<"ACCOUNT.EXAMPLE.TEST">>, <<"*.example.test">>
            )
        ),
        ?_assert(
            couch_replicator_connect:match_host_pattern(
                <<"Exact.Example.Test">>, <<"exact.example.test">>
            )
        ),
        ?_assert(
            couch_replicator_connect:match_host_pattern(
                <<"exact.example.test">>, <<"Exact.Example.Test">>
            )
        )
    ].

parse_config_test_() ->
    [
        % parse_config keeps hostname targets as binaries
        ?_assertEqual(
            [{<<"*.example.test">>, 443, <<"proxy.internal">>, 8443}],
            couch_replicator_connect:parse_config(
                "*.example.test:443:proxy.internal:8443"
            )
        ),
        % parse_config converts IPv6 targets to tuples
        ?_assertEqual(
            [{<<"*.example.test">>, 443, {8193, 3512, 0, 0, 0, 0, 0, 1}, 8443}],
            couch_replicator_connect:parse_config(
                "*.example.test:443:[2001:db8::1]:8443"
            )
        ),
        % parse_config converts IPv4 targets to tuples
        ?_assertEqual(
            [{<<"*.example.test">>, 443, {192, 168, 1, 1}, 8443}],
            couch_replicator_connect:parse_config(
                "*.example.test:443:192.168.1.1:8443"
            )
        ),
        % parse_config rejects invalid format
        ?_assertEqual(
            [],
            couch_replicator_connect:parse_config("*.example.test:443:proxy.internal")
        ),
        % parse_config rejects IPv6 patterns
        ?_assertEqual(
            [],
            couch_replicator_connect:parse_config("[2001:db8::1]:443:proxy.internal:8443")
        )
    ].

resolve_connection_test_() ->
    {setup,
        fun() ->
            meck:new(config, [passthrough]),
            meck:expect(config, get, fun
                ("replicator", "connect_to", _) ->
                    "ipv6.example.test:443:[2001:db8::1]:8443,foo.bar.com:5984:127.0.0.1:5984,*.example.test:443:proxy.internal:8443";
                (_, _, Default) ->
                    Default
            end),
            couch_replicator_connect:init()
        end,
        fun(_) ->
            meck:unload(config)
        end,
        [
            % resolve_connection returns hostname targets as strings
            ?_assertEqual(
                {"proxy.internal", 8443, "account.example.test"},
                couch_replicator_connect:resolve_connection("account.example.test", 443)
            ),
            % resolve_connection returns IPv4 targets as tuples
            ?_assertEqual(
                {{127, 0, 0, 1}, 5984, "foo.bar.com"},
                couch_replicator_connect:resolve_connection("foo.bar.com", 5984)
            ),
            % resolve_connection returns IPv6 targets as tuples
            ?_assertEqual(
                {{8193, 3512, 0, 0, 0, 0, 0, 1}, 8443, "ipv6.example.test"},
                couch_replicator_connect:resolve_connection("ipv6.example.test", 443)
            )
        ]}.
