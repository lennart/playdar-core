% Holds mappings from protocol to module:fun that can stream data for it
% Eg: protocol is the "http" bit of http://www.example.com/foo.mp3
% you call get_streamer/3 and it gives you a functor. call it and data
% will start arriving.
-module(playdar_reader_registry).

-include("playdar.hrl").
-behaviour(gen_server).

%% API
-export([start_link/0, get_streamer/3, register_handler/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
     terminate/2, code_change/3]).

-record(state, {db}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% gets a functor that will start the streaming to the given Pid
get_streamer({struct, A}, Pid, Ref) when is_list(A), is_pid(Pid) ->
    gen_server:call(?MODULE, {get_streamer, A, Pid, Ref}).

% registers protocol to module name, eg:  "http" -> http_reader
register_handler(Proto, Fun) ->
    gen_server:cast(?MODULE, {register_handler, Proto, Fun}).
    
%% gen_server callbacks
init([]) ->
    % register the protocol handlers we support natively:
    % (This hardcodedness is temporary)
    Readers = [http_reader, file_reader],
    lists:foreach( fun({Proto, F}) ->
                    playdar_reader_registry:register_handler(Proto, F)
                   end, 
                   lists:flatten( [Mod:init(protocols) || Mod <- Readers] )
                 ),
    {ok, #state{db=ets:new(stream_db,[])}}.

handle_call({get_streamer, A, Pid, Ref}, _From, State) ->
    case proplists:get_value(<<"url">>, A) of
        UrlB when is_binary(UrlB) -> 
            Url = binary_to_list(UrlB),
            [Proto|_Rest] = string:tokens(Url, ":"),
            case ets:lookup(State#state.db, Proto) of
                [{_,Fun}] ->  
                    F = fun() -> (Fun)({struct, A}, Pid, Ref) end,
                    {reply, F, State};
                _ ->
                    ?LOG(warning, "No stream handler registed for '~s'", [Proto]),
                    {reply, undefined, State}
            end
    end.

handle_cast({register_handler, Proto, Fun}, State) ->
    ?LOG(info, "handler added for protocol: ~s", [Proto]),
    ets:insert(State#state.db, {Proto, Fun}),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


