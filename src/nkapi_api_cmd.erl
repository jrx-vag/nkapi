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

-module(nkapi_api_cmd).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/2]).

-include_lib("nkevent/include/nkevent.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(DEBUG(Txt, Args, Req),
    case erlang:get(nkapi_server_debug) of
        true -> ?LLOG(debug, Txt, Args, Req);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, Req),
    lager:Type(
        [
            {session_id, Req#nkreq.session_id},
            {user_id, Req#nkreq.user_id},
            {cmd, Req#nkreq.cmd}
        ],
        "NkAPI Server Req (~s, ~s, ~s) "++Txt,
        [
            Req#nkreq.user_id,
            Req#nkreq.session_id,
            Req#nkreq.cmd
            | Args
        ])).


%% ===================================================================
%% Types
%% ===================================================================

-type state() :: nkapi_server:state().
-type req() :: #nkreq{}.

%% ===================================================================
%% Commands
%% ===================================================================


%% @doc
-spec cmd(binary(), req()) ->
    {ok, Reply::map(), state()} |
    {ack, state()} |
    {login, Reply::map(), User::nkservice:user_id(), Meta::nkservice:user_meta(), state()} |
    {error, nkservice:error(), state()}.

cmd(<<"event/subscribe">>, #nkreq{data=Data}) ->
    case nkapi_server:subscribe(self(), Data) of
        ok ->
            {ok, #{}};
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"event/unsubscribe">>, #nkreq{data=Data}) ->
    case nkapi_server:unsubscribe(self(), Data) of
        ok ->
            {ok, #{}};
        {error, Error} ->
            {error, Error}
    end;

%% Gets [#{class=>...}]
cmd(<<"event/get_subscriptions">>, Req) ->
    Self = self(),
    spawn_link(
        fun() ->
            Reply = nkapi_server:get_subscriptions(Self),
            nkapi_server:reply({ok, Reply, Req})
        end),
    {ack};

cmd(<<"event/send">>, #nkreq{data=Data}) ->
    case nkapi_server:event(self(), Data) of
        ok ->
            {ok, #{}};
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"event/send_to_user">>, #nkreq{srv_id=SrvId, data=Data}) ->
    #{user_id:=UserId} = Data,
    Event = #nkevent{
        class = <<"api">>,
        subclass = <<"user">>,
        type = maps:get(type, Data, <<>>),
        srv_id = SrvId,
        obj_id = UserId,
        body = maps:get(body, Data, #{})
    },
    case nkevent:send(Event) of
        ok ->
            {ok, #{}};
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"session/ping">>, _Req) ->
    {ok, #{now=>nklib_util:m_timestamp()}};

cmd(<<"session/stop">>, #nkreq{data=Data}) ->
    case Data of
        #{session_id:=SessId} ->
            %% TODO: check if authorized
            case nkapi_server:find_session(SessId) of
                {ok, _User, Pid} ->
                    nkapi_server:stop(Pid),
                    {ok, #{}};
                not_found ->
                    {error, session_not_found}
            end;
        _ ->
            nkapi_server:stop(self()),
            {ok, #{}}
    end;

cmd(<<"session/cmd">>, #nkreq{data=Data}=Req) ->
    #{session_id:=SessId} = Data,
    case nkapi_server:find_session(SessId) of
        {ok, _User, Pid} ->
            _ = spawn_link(fun() -> launch_cmd(Req, Pid) end),
            ack;
        not_found ->
            {error, session_not_found}
    end;

cmd(<<"session/log">>, #nkreq{data=Data}) ->
    Txt = "API Session Log: ~p",
    case maps:get(level, Data) of
        7 -> lager:debug(Txt, [Data]);
        6 -> lager:info(Txt, [Data]);
        5 -> lager:notice(Txt, [Data]);
        4 -> lager:warning(Txt, [Data]);
        _ -> lager:error(Txt, [Data])
    end,
    {ok, #{}};

cmd(<<"session/api_test">>, #nkreq{data=#{data:=Data}}) ->
    {ok, #{reply=>Data}};

cmd(<<"session/api_test.async">>, #nkreq{data=#{data:=Data}}=Req) ->
    spawn_link(
        fun() ->
            timer:sleep(2000),
            nkapi_server:reply({ok, #{reply=>Data}, Req})
        end),
    ack;

cmd(Cmd, Req) ->
    ?LLOG(notice, "command not implemented: ~s", [Cmd], Req),
    {error, not_implemented}.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
launch_cmd(#nkreq{data=#{cmd:=Cmd}=Data}=Req, Pid) ->
    CmdData = maps:get(data, Data, #{}),
    case nkapi_server:cmd(Pid, Cmd, CmdData) of
        {ok, <<"ok">>, ResData} ->
            nkapi_server:reply({ok, ResData, Req});
        {ok, <<"error">>, #{<<"code">>:=Code, <<"error">>:=Error}} ->
            nkapi_server:reply({error, {Code, Error}, Req});
        {ok, Res, _ResData} ->
            Ref = nklib_util:uid(),
            ?LLOG(notice, "invalid reply: ~p (~p)", [Res, Ref], Req),
            nkapi_server:reply({error, {internal_error, Ref}, Req});
        {error, Error} ->
            nkapi_server:reply({error, Error, Req})
    end.

