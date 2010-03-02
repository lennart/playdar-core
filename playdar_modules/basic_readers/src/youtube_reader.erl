-module(youtube_reader).
-behaviour(playdar_reader).
-behaviour(gen_server).
-include("playdar.hrl").
-include_lib("kernel/include/file.hrl").

-define(HTTP_HEADERS_TIMEOUT, 5000).
-define(HTTP_STREAM_TIMEOUT, 10000).

-export([handle_cast/2, handle_info/2, init/1, terminate/2]).

-export([start_link/3, reader_protocols/0, scrape_youtube/1]).

-record(state, {port,target,ref}).

start_link(A, Pid, Ref) ->
  spawn_link(fun()->run(A,Pid,Ref)end).


init([Pid, Ref]) ->
    Exe = "/usr/local/bin/ffmpeg -i - -v -1 -f mp3 -ab 128000 -",
    
    Port = open_port({spawn, Exe}, [binary, stream]),
    {ok, #state{port=Port, target=Pid, ref=Ref}}.


reader_protocols() ->
  [ {"youtube", {?MODULE, start_link}} ].

http_fetch(Url) ->
  case http:request(get, {Url, []}, [], []) of
    {ok, {_, _, Body}} ->
      {ok, Body};
    {error, Reason} ->
      {error, Reason}
  end.

% starts sending data to Pid
run({struct, A}, Pid, Ref) ->
  YouTubeUrl = binary_to_list(proplists:get_value(<<"url">>, A)),
  [VideoId|_Proto] = lists:reverse(string:tokens(YouTubeUrl, "/")),
  case catch scrape_youtube(VideoId) of
    {'EXIT', Reason} ->
      ?LOG(info, "Youtube Video could not be streamed: ~p",[Reason]);
    {error, Reason} ->
      ?LOG(info, "Youtube Video could not be streamed: ~p",[Reason]);
    DirectUrl ->
      ?LOG(info, "Requesting ~p", [DirectUrl]),
      {ok, Id} = http:request(get, {DirectUrl, []}, [], 
        [{sync, false}, 
          {stream, self}, 
          {version, 1.1}, 
          {body_format, binary}]),
      receive
        {http, {Id, stream_start, Headers}} ->
          ?LOG(info, "Serving stream: ~s", [DirectUrl]),
          % snag the content-length and content-type headers:
          ContentType = proplists:get_value("content-type", Headers, 
            "binary/unknown-not-specified"),
          ContentLength = proplists:get_value("content-length", Headers),
          % some results from web indexes to audio files have expired and
          % just give you an html response that says bugger off:
          case string:str(ContentType, "text/html") of
            0 ->
              ResponseHeaders = [{"content-type", "audio/mpeg"}],
              Pid ! {Ref, headers, ResponseHeaders},
              start_transcoding(Id, Pid, Ref);
            _ ->
              ?LOG(warning, "Got content type of ~s - aborting, probably failed.", [ContentType]),
              Pid ! {Ref, error, "Suspicious content type header"}
          end;

        {http, {Id, error, Reason}} ->
          ?LOG(warning, "HTTP req failed for ~s",[DirectUrl]),
          Pid ! {Ref, error, Reason}

      after ?HTTP_HEADERS_TIMEOUT ->
          ?LOG(warning, "HTTP timeout on receiving headers for ~s",[DirectUrl]),
          Pid ! {Ref, error, timeout}
      end
  end.


handle_cast({http_input, Data}, #state{port = Port, target = Pid, ref = Ref} = State) ->
  Port ! {self(), {command, Data}},
  {noreply, #state{port = Port, target = Pid, ref=Ref}};

handle_cast({http_input, eof}, State) ->
  {stop, normal, State}.

handle_info(Info, #state{port = Port, target = Pid, ref = Ref} = State) ->
  case Info of
    {Port, {data, Data}} ->
      Pid ! {Ref, data, Data},
      {noreply, State};
    Else ->
      io:format("Else: ~p~n", [Else]),
      {noreply, State}
  end.

terminate(Reason, #state{port = Port, target = Pid} = State) ->
  io:format("Terminating ~p~n",[Reason]),
  port_close(Port).

start_transcoding(Id, Pid, Ref) ->
  {ok, ServerPid} = gen_server:start_link(?MODULE, [Pid, Ref], []),
  io:format("Starting Transcoding Process: ~p,~p,~p,~n",[Id,Pid,Ref]),
  start_streaming(ServerPid, Id, Pid, Ref).


start_streaming(ServerPid, Id, Pid, Ref) ->
  receive
    {http, {Id, stream, Bin}} ->
      gen_server:cast(ServerPid, {http_input, Bin}), 
      start_streaming(ServerPid, Id, Pid, Ref);

    {http, {Id, error, Reason}} ->
      gen_server:cast(ServerPid, {http_input, eof}),
      Pid ! {Ref, error, Reason};

    {http, {Id, stream_end, _Headers}} ->
      gen_server:cast(ServerPid, {http_input, eof}),
      Pid ! {Ref, eof}

  after ?HTTP_STREAM_TIMEOUT ->
      ?LOG(warning, "Timeout receiving stream", []),
      Pid ! {Ref, error, timeout}
  end.

scrape_youtube(VideoId) ->
  case catch get_stream_map_for_video_id(VideoId) of
    {'EXIT', Reason} ->
      io:format("This Youtube Video could not be streamed"),
      throw({error, not_found});
    {error, Reason} ->
      io:format("This Youtube Video could not be streamed"),
      throw({error, not_found});
    StreamMap ->
      {Format, Url} = lists:last(lists:reverse(StreamMap)),
      ?LOG(info, "Will stream format ~p",[Format]),
      Url
  end.




get_stream_map_for_video_id(VideoId) ->
  ScrapeString = "SWF_ARGS': ",
  ?LOG(debug, "Youtube Scraping started",[]),
  {ok, Body} = http_fetch(io_lib:format("http://www.youtube.com/watch?v=~s",[VideoId])),
  ?LOG(debug, "Youtube Scraped",[]),
  Tree = mochiweb_html:parse(Body),
  ?LOG(debug, "Youtube HTML parsed",[]),
  Scripts = lists:flatten(lists:foldl(fun({<<"script">>, _Attrs, Content}, Acc) -> [Content|Acc] end, [], mochiweb_xpath:execute("//script",Tree))),
  ?LOG(debug, "Youtube Javascripts extracted",[]),
  SwfArgs = [ {Value, Index} || Value <- Scripts, is_binary(Value), (Index = string:str(binary_to_list(Value), ScrapeString)) =/= 0],
  ?LOG(debug, "Youtube SWF_ARGS extracted",[]),
  case catch SwfArgs of
    {'EXIT', Reason} ->
      ?LOG(error, "Youtube Scraping exited: ~p",[Reason]),
      {error, not_found};
    {error, Reason} ->
      ?LOG(error, "Youtube Scraping failed: ~p",[Reason]),
      {error, not_found};
    [{Code, Index}] ->
      Rest = string:substr(binary_to_list(Code),Index+string:len(ScrapeString)),
      RawJson = list_to_binary(string:substr(Rest, 1, string:str(Rest,"}"))),
      ?LOG(debug, "Youtube Parsing SWF_ARGS started: ~p",[RawJson]),
      case catch mochijson2:decode(RawJson) of
        {'EXIT', Reason} ->
          ?LOG(error, "Youtube Scraping exited: ~p",[Reason]),
          {error, not_found};
        {error, Reason} ->
          ?LOG(error, "Youtube Scraping failed: ~p",[Reason]),
          {error, not_found};
        {struct, Json} ->
          Map = mochiweb_util:unquote(proplists:get_value(<<"fmt_stream_map">>,Json)),
          [{Format, Url} || Token <- string:tokens(Map,","), is_list([Format,Url] = string:tokens(Token,"|"))];
        _ ->
          {error, not_found}
      end;
    _ ->
      {error, not_found}
  end.


