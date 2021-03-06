%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc GELF logging plugin for external API
-module(nkapi_log_gelf).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send/3, send/6]).
-export([plugin_deps/0, plugin_syntax/0, plugin_start/2, plugin_stop/2]).
-export([api_server_cmd/2]).

-include("nkapi.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc
send(Srv, Source, Short) ->
    send(Srv, Source, Short, <<>>, 1, #{}).

%% @doc
send(Srv, Source, Short, Long, Level, Meta) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            case nklib_log:find({?MODULE, SrvId}) of
                {ok, Pid} ->
                    Meta2 = Meta#{srv_id=>SrvId},
                    Msg1 = #{
                        host => Source,
                        message => Short,
                        level => Level,
                        meta => Meta2
                    },
                    Msg2 = case Long of
                        <<>> -> Msg1;
                        _ -> Msg1#{full_message=>Long}
                    end,
                    nklib_log:message(Pid, Msg2);
                not_found ->
                    {error, log_server_not_found}
            end;
        not_found ->
            {error, service_not_found}
    end.




%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkapi].


plugin_syntax() ->
    #{
        api_gelf_server => binary,
        api_gelf_port => {integer, 1, 65535}
    }.


%% @private
%% When the plugin starts, it adds a user process to the service (named api_gelf)
%% that starts with nklib_log:start_link({?MODULE, SrvId}, nklib_log_gelf, Opts),
%% and it is registered under {?MODULE, SrvId}
plugin_start(Config, #{id:=Id}) ->
    case Config of
        #{api_gelf_server:=Server} ->
            Port = maps:get(api_gelf_port, Config, 12201),
            Opts = #{server=>Server, port=>Port},
            Args = [{?MODULE, Id}, nklib_log_gelf, Opts],
            case nkservice_srv:start_proc(Id, api_gelf, nklib_log, Args) of
                {ok, _} ->
                    {ok, Config};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {ok, Config}
    end.


plugin_stop(Config, #{id:=Id}) ->
    nklib_log:stop({?MODULE, Id}),
    {ok, Config}.




%% ===================================================================
%% Implemented Callbacks
%% ===================================================================


api_server_cmd(#nkapi_req{class=session, cmd=log}=Req, State) ->
    lager:error("LOG GELF"),

    #nkapi_req{srv_id=SrvId, data=Data, user_id=User, session_id=Session} = Req,
    #{source:=Source, message:=Short, level:=Level} = Data,
    Long = maps:get(full_message, Data, <<>>),
    Meta1 = maps:get(meta, Data, #{}),
    Meta2 = Meta1#{user=>User, session_id=>Session},
    _Res = send(SrvId, Source, Short, Long, Level, Meta2),
    {ok, #{}, State};

api_server_cmd(_Req, _State) ->
    continue.




%% ===================================================================
%% Internal
%% ===================================================================


% %% @private
% get_log_msg(#api_req{srv_id=SrvId, data=Data, user=User, session_id=Session}) ->
%     #{source:=Source, message:=Short, level:=Level} = Data,
%     Msg = [
%         {version, <<"1.1">>},
%         {host, Source},
%         {message, Short},
%         {level, Level},
%         {<<"_srv_id">>, SrvId},
%         {<<"_user">>, User},
%         {<<"_session_id">>, Session},
%         case maps:get(full_message, Data, <<>>) of
%             <<>> -> [];
%             Full -> [{full_message, Full}]
%         end
%         |
%         case maps:get(meta, Data, #{}) of
%             Meta when is_map(Meta) ->
%                 [{<<$_, Key/binary>>, Val} || {Key, Val}<- maps:to_list(Meta)];
%             _ ->
%                 []
%         end
%     ],
%     maps:from_list(lists:flatten(Msg)).


