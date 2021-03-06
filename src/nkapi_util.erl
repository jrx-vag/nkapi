%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(nkapi_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([http/3, http_upload/7, http_download/6]).
-export([api_error/2]).
-export([get_web_servers/3, get_api_webs/3, get_api_sockets/3]).
-export([parse_api_server/3, parse_web_server/3]).

-include_lib("nkpacket/include/nkpacket.hrl").
-include_lib("nklib/include/nklib.hrl").


%%-define(API_TIMEOUT, 30).
%%
-define(HTTP_CONNECT_TIMEOUT, 15000).
-define(HTTP_RECV_TIMEOUT, 5000).


%% ===================================================================
%% Public
%% ===================================================================


%% @private
http(Method, Url, Opts) ->
    Headers1 = maps:get(headers, Opts, []),
    {Headers2, Body2} = case Opts of
        #{body:=Body} when is_map(Body) ->
            {
                [{<<"Content-Type">>, <<"application/json">>}|Headers1],
                nklib_json:encode(Body)

            };
        #{body:=Body} ->
            {
                Headers1,
                to_bin(Body)                
            };
        #{form:=Form} ->
            {Headers1, {form, Form}};
        #{multipart:=Parts} ->
            {Headers1, {multipart, Parts}};
        _ ->
            {[{<<"Content-Length">>, <<"0">>}|Headers1], <<>>}
    end,
    Headers3 = case Opts of
        #{bearer:=Bearer} ->
            [{<<"Authorization">>, <<"Bearer ", Bearer/binary>>}|Headers2];
        #{user:=User, pass:=Pass} ->
            Auth = base64:encode(list_to_binary([User, ":", Pass])),
            [{<<"Authorization">>, <<"Basic ", Auth/binary>>}|Headers2];
        _ ->
            Headers2
    end,
%%    Ciphers = ssl:cipher_suites(),
    % Hackney fails with its default set of ciphers
    % See hackney.ssl#44
    HttpOpts = [
        {connect_timeout, ?HTTP_CONNECT_TIMEOUT},
        {recv_timeout, ?HTTP_RECV_TIMEOUT},
        insecure,
        with_body,
        {pool, default}
%%        {ssl_options, [{ciphers, Ciphers}]}
    ],
    Start = nklib_util:l_timestamp(),
    Url2 = list_to_binary([Url]),
    case hackney:request(Method, Url2, Headers3, Body2, HttpOpts) of
        {ok, Code, Headers, RespBody} when Code==200; Code==201 ->
            Time = nklib_util:l_timestamp() - Start,
            {ok, Headers, RespBody, Time div 1000};
        {ok, Code, Headers, RespBody} ->
            {error, {http_code, Code, Headers, RespBody}};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
http_upload(Url, User, Pass, Class, ObjId, Name, Body) ->
    Id = nkapi_server_http:filename_encode(Class, ObjId, Name),
    <<"/", Base/binary>> = nklib_parse:path(Url),
    Url2 = list_to_binary([Base, "/upload/", Id]),
    Opts = #{
        user => to_bin(User),
        pass => to_bin(Pass),
        body => Body
    },
    http(post, Url2, Opts).


%% @doc
http_download(Url, User, Pass, Class, ObjId, Name) ->
    Id = nkapi_server_http:filename_encode(Class, ObjId, Name),
    <<"/", Base/binary>> = nklib_parse:path(Url),
    Url2 = list_to_binary([Base, "/download/", Id]),
    Opts = #{
        user => to_bin(User),
        pass => to_bin(Pass)
    },
    http(get, Url2, Opts).



%% @private
-spec api_error(nkservice:id(), nkservice:error()) ->
    {binary(), binary()}.

api_error(SrvId, Error) ->
    {Code, Reason} = case SrvId:api_error(SrvId, Error) of
        {ErrCode, Fmt, List} when is_list(Fmt), is_list(List) ->
            {ErrCode, get_error_fmt(Fmt, List)};
        {Fmt, List} when is_list(Fmt), is_list(List) ->
            {Error, get_error_fmt(Fmt, List)};
        {ErrCode, ErrReason} when is_list(ErrReason); is_binary(ErrReason) ->
            {ErrCode, ErrReason};
        ErrReason when is_list(ErrReason) ->
            {Error, ErrReason};
        continue ->
            % This error is not in any table, but it can be an already processed one
            case Error of
                {exit, Exit} ->
                    Ref = make_ref(),
                    lager:notice("Internal API error ~p: ~p", [Ref, Exit]),
                    {internal_error, get_error_fmt("Internal error '~p'", [Ref])};
                {ErrCode, ErrReason} when is_binary(ErrCode), is_binary(ErrReason) ->
                    {ErrCode, ErrReason};
                _ ->
                    lager:notice("Unrecognized API error: ~p", [Error]),
                    {Error, <<>>}
            end;
        _ ->
            {Error, <<>>}
    end,
    {get_error_code(Code), to_bin(Reason)}.


%% @private
get_error_code(Term) when is_atom(Term); is_binary(Term); is_list(Term) ->
    to_bin(Term);

get_error_code(Tuple) when is_tuple(Tuple) ->
    get_error_code(element(1, Tuple));

get_error_code(Error) ->
    lager:notice("Invalid format in API reason: ~p", [Error]),
    <<"internal_error">>.


%% @private
get_error_fmt(Fmt, List) ->
    case catch io_lib:format(Fmt, List) of
        {'EXIT', _} ->
            lager:notice("Invalid format API reason: ~p, ~p", [Fmt, List]),
            <<>>;
        Val ->
            list_to_binary(Val)
    end.


%% @private
get_web_servers(SrvId, List, Config) ->
    WebPath = case Config of
        #{web_server_path:=UserPath} -> 
            UserPath;
        _ ->
            Priv = list_to_binary(code:priv_dir(nkapi)),
            <<Priv/binary, "/www">>
    end,
    NetOpts = nkpacket_util:get_plugin_net_opts(Config),
    WebOpts2 = NetOpts#{
        class => {nkapi_web_server, SrvId},
        http_proto => {static, #{path=>WebPath, index_file=><<"index.html">>}}
    },
    [{Conns, maps:merge(ConnOpts, WebOpts2)} || {Conns, ConnOpts} <- List].



%% @private
get_api_webs(SrvId, ApiSrv, Config) ->
    get_api_webs(SrvId, ApiSrv, Config, []).


%% @private
get_api_webs(_SrvId, [], _Config, Acc) ->
    Acc;

get_api_webs(SrvId, [{List, Opts}|Rest], Config, Acc) ->
    List2 = [
        {nkpacket_protocol_http, Proto, Ip, Port}
        ||
        {nkapi_server, Proto, Ip, Port} <- List, 
        Proto==http orelse Proto==https
    ],
    Acc2 = case List2 of
        [] ->
            [];
        _ ->
            Path1 = nklib_util:to_list(maps:get(path, Opts, <<>>)),
            Path2 = case lists:reverse(Path1) of
                [$/|R] -> lists:reverse(R);
                _ -> Path1
            end,
            CowPath = Path2 ++ "/[...]",
            Routes = [{'_', [{CowPath, nkapi_server_http, [{srv_id, SrvId}]}]}],
            NetOpts = nkpacket_util:get_plugin_net_opts(Config),
            Opts2 = NetOpts#{
                class => {nkapi_server, SrvId},
                http_proto => {dispatch, #{routes => Routes}}
            },
            [{List2, Opts2}|Acc]
    end,
    get_api_webs(SrvId, Rest, Config, Acc2).


%% @private
get_api_sockets(SrvId, ApiSrv, Config) ->
    get_api_sockets(SrvId, ApiSrv, Config, []).


%% @private
get_api_sockets(_SrvId, [], _Config, Acc) ->
    Acc;

get_api_sockets(SrvId, [{List, Opts}|Rest], Config, Acc) ->
    List2 = [
        {nkapi_server, Proto, Ip, Port}
        ||
        {nkapi_server, Proto, Ip, Port} <- List, 
        Proto==ws orelse Proto==wss orelse Proto==tcp orelse Proto==tls
    ],
    Timeout = maps:get(api_server_tiemout, Config, 180),
    NetOpts = nkpacket_util:get_plugin_net_opts(Config),
    Opts2 = NetOpts#{
        path => maps:get(path, Opts, <<"/">>),
        class => {nkapi_server, SrvId},
        get_headers => [<<"user-agent">>],
        idle_timeout => 1000 * Timeout,
        debug => false
    },
    get_api_sockets(SrvId, Rest, Config, [{List2, maps:merge(Opts, Opts2)}|Acc]).


%% @private
to_bin(Term) -> nklib_util:to_binary(Term).



%% ===================================================================
%% Private
%% ===================================================================

%% @private
parse_api_server(api_server, {multi, Multi}, _Ctx) ->
    {ok, {multi, Multi}};

parse_api_server(api_server, Url, _Ctx) ->
    case nklib_parse:uris(Url) of
        error ->
            error;
        List ->
            case make_api_listen(List, []) of
                error ->
                    error;
                List2 ->
                    case nkpacket:multi_resolve(List2, #{resolve_type=>listen}) of
                        {ok, List3} ->
                            {ok, {multi, List3}};
                        _ ->
                            error
                    end
            end
    end.


%% @private
parse_web_server(_Key, {multi, Multi}, _Ctx) ->
    {ok, {multi, Multi}};

parse_web_server(web_server, Url, _Ctx) ->
    Opts = #{valid_schemes=>[http, https], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, {multi, List}};
        _ -> error
    end.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
make_api_listen([], Acc) ->
    lists:reverse(Acc);

make_api_listen([#uri{scheme=nkapi}=Uri|Rest], Acc) ->
    make_api_listen(Rest, [Uri|Acc]);

make_api_listen([#uri{scheme=Sc, ext_opts=Opts}=Uri|Rest], Acc)
    when Sc==tcp; Sc==tls; Sc==ws; Sc==wss; Sc==http; Sc==https ->
    Uri2 = Uri#uri{scheme=nkapi, opts=[{<<"transport">>, Sc}|Opts]},
    make_api_listen(Rest, [Uri2|Acc]);

make_api_listen(_D, _Acc) ->
    error.
