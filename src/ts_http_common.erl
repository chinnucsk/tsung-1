%%%  This code was developped by IDEALX (http://IDEALX.org/) and
%%%  contributors (their names can be found in the CONTRIBUTORS file).
%%%  Copyright (C) 2000-2001 IDEALX
%%%
%%%  This program is free software; you can redistribute it and/or modify
%%%  it under the terms of the GNU General Public License as published by
%%%  the Free Software Foundation; either version 2 of the License, or
%%%  (at your option) any later version.
%%%
%%%  This program is distributed in the hope that it will be useful,
%%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%  GNU General Public License for more details.
%%%
%%%  You should have received a copy of the GNU General Public License
%%%  along with this program; if not, write to the Free Software
%%%  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
%%% 

%%% common functions used by http clients to:
%%%  - parse response from HTTP server

-module(ts_http_common).
-vc('$Id$ ').
-author('nicolas.niclausse@IDEALX.com').

-include("ts_profile.hrl").
-include("ts_http.hrl").

-include("ts_config.hrl").

-include_lib("xmerl/inc/xmerl.hrl").

-export([
		 http_get/1,
		 http_get_ifmodsince/1,
		 http_post/1,
		 set_msg/1, set_msg/2,
		 parse/2,
		 parse_URL/1,
         parse_config/2
		]).

%%----------------------------------------------------------------------
%% Func: http_get/1
%% Args: #http_request
%%----------------------------------------------------------------------
http_get(Req=#http_request{url=URL, version=Version, cookie=Cookie,
                           server_name = Host}) ->
	list_to_binary([?GET, " ", URL," ", "HTTP/", Version, ?CRLF, 
                    "Host: ", Host, ?CRLF,
                    user_agent(),
                    get_cookie(Cookie),
                    ?CRLF]).

%%----------------------------------------------------------------------
%% Func: http_get_ifmodsince/1
%% Args: #http_request
%%----------------------------------------------------------------------
http_get_ifmodsince(Req=#http_request{url=URL, version=Version, cookie=Cookie,
                                      get_ims_date=Date, server_name=Host}) ->
	list_to_binary([?GET, " ", URL," ", "HTTP/", Version, ?CRLF,
                    ["If-Modified-Since: ", Date, ?CRLF],
                    "Host: ", Host, ?CRLF,
                    user_agent(),
                    get_cookie(Cookie),
                    ?CRLF]).

%%----------------------------------------------------------------------
%% Func: http_post/1
%% Args: #http_request
%% TODO: Content-Type ?
%%----------------------------------------------------------------------
http_post(Req=#http_request{url=URL, version=Version, cookie=Cookie, body=Content, 
                            server_name=Host}) ->
	ContentLength=integer_to_list(size(Content)),
	?LOGF("Content Length of POST: ~p~n.", [ContentLength], ?DEB),
	Headers = [?POST, " ", URL," ", "HTTP/", Version, ?CRLF,
               "Host: ", Host, ?CRLF,
               user_agent(),
               get_cookie(Cookie),
               "Content-Length: ",ContentLength, ?CRLF,
               ?CRLF
              ],
	list_to_binary([Headers, Content ]).

%%----------------------------------------------------------------------
%% some HTTP headers functions
%%----------------------------------------------------------------------
user_agent() ->
	["User-Agent: ", ?USER_AGENT, ?CRLF].

get_cookie([])   -> [];
get_cookie(none) -> [];
get_cookie(Cookie) ->
	["Cookie: ", Cookie, ?CRLF].


%%----------------------------------------------------------------------
%% Func: parse_config/2
%% Args: Element, Config
%% Returns: List
%% Purpose: parse a request defined in the XML config file
%%----------------------------------------------------------------------
parse_config(Element = #xmlElement{name=http}, 
             Config=#config{curid= Id, session_tab = Tab,
                            sessions = [CurS |SList]}) ->
    Version  = ts_config:getAttr(Element#xmlElement.attributes, version),
    URL      = ts_config:getAttr(Element#xmlElement.attributes, url),
    Contents = ts_config:getAttr(Element#xmlElement.attributes, contents),
    Date     = ts_config:getAttr(Element#xmlElement.attributes, date),
    Method = case ts_config:getAttr(Element#xmlElement.attributes, method) of 
                 "GET"    -> get;
                 "GETIMS" -> getims;
                 "POST"   -> post;
                 Other ->
                     ?LOGF("Bad method ! ~p ~n",[Other],?ERR),
                     get
             end,
    ServerName = case ets:lookup(Tab,{http_server_name, value}) of 
                     [] ->
                         ?config(server_name);
                     [{_Key, SName}] ->
                         SName
                 end,
    Msg = set_msg(#http_request{url         = URL,
                                method      = Method,
                                version     = Version,
                                get_ims_date= Date,
                                server_name = ServerName,
                                body        = list_to_binary(Contents)}, 0),
    ets:insert(Tab,{{CurS#session.id, Id}, Msg}),
    lists:foldl( {ts_config, parse},
                 Config#config{},
                 Element#xmlElement.content);
%% Parsing default values
parse_config(Element = #xmlElement{name=default}, Conf = #config{session_tab = Tab}) ->
    case ts_config:getAttr(Element#xmlElement.attributes, name) of
        "server_name" ->
            Val = ts_config:getAttr(Element#xmlElement.attributes, value),
            ets:insert(Tab,{{http_server_name, value}, Val})
    end,
    lists:foldl( {ts_config, parse}, Conf, Element#xmlElement.content);
%% Parsing other elements
parse_config(Element = #xmlElement{}, Conf = #config{}) ->
    lists:foldl( {ts_config, parse}, Conf, Element#xmlElement.content);
%% Parsing non #xmlElement elements
parse_config(Element, Conf = #config{}) ->
    Conf.

%%----------------------------------------------------------------------
%% Func: parse/2
%% Args: Data, State
%% Returns: {NewState, Options for socket (list)}
%% Purpose: parse the response from the server and keep information
%%  about the response if State#state_rcv.session
%%----------------------------------------------------------------------

%% new connection, headers parsing
parse(Data, State) when (State#state_rcv.session)#http.status == none ->
	List = binary_to_list(Data),
	%%	regexp:split is much less efficient ! 
	StartHeaders = string:str(List, "\r\n\r\n"),
	case StartHeaders of 
		0 -> 
			ts_mon:addcount({ parse_error }),
			{State#state_rcv{session= #http{}, ack_done = true, 
							 datasize = size(Data)}, []};
		_ -> 
			Headers = string:substr(List, 1, StartHeaders-1),
			[Status, ParsedHeader] = request_header(Headers),
			?LOGF("HTTP (status=~p) Headers: ~p ~n", [Status, ParsedHeader], ?DEB),
			Cookie = parse_cookie(ParsedHeader),
			ts_mon:addcount({ Status }),
			case {httpd_util:key1search(ParsedHeader,"content-length"), Status} of
				{undefined, 304} -> % Not modified, no body
					?LOG("HTTP Not modified~n", ?DEB),
                    {State#state_rcv{session= #http{}, ack_done = true,
                                     datasize = 0, % FIXME: count headers ?
                                     dyndata= Cookie}, []};
				{undefined, _} -> % no content-length, must be chunked
					HeaderSize = length(Headers),
                    << BinHead:HeaderSize/binary, Body/binary >> = Data,
                    parse_chunked(httpd_util:key1search(ParsedHeader,
                                                        "transfer-encoding"),
                                  Body, State, Cookie);
				{Length, _} ->
					CLength = list_to_integer(Length)+4,
					?LOGF("HTTP Content-Length:~p~n",[CLength], ?DEB),
					HeaderSize = length(Headers),
					BodySize = size(Data)-HeaderSize,
					if
						BodySize == CLength ->  % end of response
							{State#state_rcv{session= #http{}, ack_done = true,
											 datasize = BodySize,
											 dyndata= Cookie}, []};
						BodySize > CLength  ->
							?LOGF("Error: HTTP Body > Content-Length !:~p~n",
								  [CLength], ?ERR),
							ts_mon:addcount({ http_bad_content_length }),
							{State#state_rcv{session= #http{}, ack_done = true,
											 datasize = BodySize, 
											 dyndata= Cookie}, []};
						true ->
							Http = #http{content_length = CLength,
										 status         = Status,
										 body_size      = BodySize},
							{State#state_rcv{session = Http, ack_done = false,
											 datasize = BodySize,
											 dyndata=Cookie},[]}
					end
			end
	end;

%% FIXME: handle the case where the Headers are not complete in the first message
%% current connection
parse(Data, State) when (State#state_rcv.session)#http.chunk_toread >0 ->
    Http = State#state_rcv.session,
    ChunkSizePending = Http#http.chunk_toread,
    BodySize = Http#http.body_size,
    Cookie = State#state_rcv.dyndata,
    read_chunk_data(Data, State, Cookie, ChunkSizePending , BodySize);
parse(Data, State) ->
	DataSize = size(Data),
	?LOGF("HTTP Body size=~p ~n",[DataSize], ?DEB),
	Size = (State#state_rcv.session)#http.body_size + DataSize,
	CLength = (State#state_rcv.session)#http.content_length,
	case Size of 
		CLength -> % end of response
			{State#state_rcv{session= #http{}, ack_done = true, datasize = Size},
			 []};
		_ ->
			Http = (State#state_rcv.session)#http{body_size = Size},
			{State#state_rcv{session= Http, ack_done = false, datasize = Size}, []}
	end.
												 
%%----------------------------------------------------------------------
%% Func: request_header/1
%% Returns: [HTTPStatus = integer, Headers = list]
%% Purpose: parse HTTP headers. 
%%----------------------------------------------------------------------
request_header(Header)->
    [ResponseLine|HeaderFields] = httpd_parse:split_lines(Header),
    ParsedHeader = httpd_parse:tagup_header(HeaderFields),
	[get_status(ResponseLine), ParsedHeader].

%%----------------------------------------------------------------------
%% Func: get_status/1
%% Purpose: returns HTTP status code = integer()
%%----------------------------------------------------------------------
get_status(Line) ->
	StartStatus = string:str(Line, " "),
	Status = string:substr(Line, StartStatus+1, 3),
	list_to_integer(Status).

%%----------------------------------------------------------------------
%% Func: parse_chunked/4
%% Purpose: parse 'Transfer-Encoding: chunked' for HTTP/1.1
%% Returns: {NewState= record(state_rcv), SockOpts}
%%----------------------------------------------------------------------
parse_chunked(undefined, Data, State, Cookie) ->
    ?LOGF("No content length ! ~p~n",[Data], ?ERR),
    ts_mon:addcount({ http_no_content_length }),
    { State#state_rcv{session=#http{}, ack_done=true, datasize=0 } , [] };
parse_chunked("chunked", <<CRLF:4/binary,Body/binary>>, State, Cookie)->
    ?LOGF("Chunked tranfer encoding, datasize=~p~n", [size(Body)] ,?DEB),
    read_chunk(Body, State, Cookie, 0, 0);
parse_chunked(Transfer, Data, State, Cookie) ->
    ?LOGF("Unknown transfer type ! ~p~n",[Transfer], ?WARN),
    ts_mon:addcount({ http_unknown_tranfer }),
    { State#state_rcv{session=#http{}, ack_done=true, datasize=0 } , [] }.

%%----------------------------------------------------------------------
%% Func: read_chunk/5
%% Purpose: the real stuff for parsing chunks is here
%% Returns: {NewState= record(state_rcv), SockOpts}
%%----------------------------------------------------------------------
read_chunk(<<>>, State, Cookie, Int, Acc) ->
    ?LOG("NO Data in chunk ! ~n", ?WARN),
	% FIXME: should we check if Headers has just been received and the
	% returns a new #http record ?
    { State, [] }; % read more data
%% this code has been inspired by inets/http_lib.erl
read_chunk(<<Char:1/binary, Data/binary>>, State, Cookie, Int, Acc) ->
    case Char of
	<<C>> when $0=<C,C=<$9 ->
	    read_chunk(Data, State, Cookie,16*Int+(C-$0), Acc+1);
	<<C>> when $a=<C,C=<$f ->
	    read_chunk(Data, State, Cookie,16*Int+10+(C-$a), Acc+1);
	<<C>> when $A=<C,C=<$F ->
	    read_chunk(Data, State, Cookie,16*Int+10+(C-$A), Acc+1);
%	<<$;>> when Int>0 ->
%	    ExtensionList=read_chunk_ext_name(Data, State, Cookie,[],[]),
%	    read_chunk_data(Data, State, Cookie,Int+1,ExtensionList);
%	<<$;>> when Int==0 ->
%	    ExtensionList=read_chunk_ext_name(Data, State, Cookie,[],[]),
%	    read_data_lf(),
	<<?CR>> when Int>0 ->
	    read_chunk_data(Data,State,Cookie,Int+3, Acc+1);
	<<?CR>> when Int==0 -> %% should be the end of tranfer
            ?LOGF("Finish tranfer chunk ~p~n", [binary_to_list(Data)] ,?DEB),
            {State#state_rcv{session= #http{}, ack_done = true,
                             datasize = Acc, %% FIXME: is it the correct size?
                             dyndata= Cookie}, []};
	<<C>> when C==$ -> % Some servers (e.g., Apache 1.3.6) throw in
			   % additional whitespace...
	    read_chunk(Data, State, Cookie, Int, Acc+1);
	_Other ->
            ?LOGF("Unexpected error while parsing chunk ~p~n", [_Other] ,?DEB),
			ts_mon:count({http_unexpected_chunkdata}),
            {State#state_rcv{session= #http{}, ack_done = true}, []}
    end.

%%----------------------------------------------------------------------
%% Func: read_chunk_data/5
%% Purpose: read 'Int' bytes of data
%% Returns: {NewState= record(state_rcv), SockOpts}
%%----------------------------------------------------------------------
read_chunk_data(Data, State, Cookie,Int, Acc) when size(Data) >= Int->
    ?LOGF("Read Chunked of size ~p~n", [Int] ,?DEB),
    <<NewData:Int/binary, Rest/binary >> = Data,
    read_chunk(Rest, State, Cookie, 0, Int + Acc);
read_chunk_data(Data, State, Cookie,Int, Acc) -> % not enough data in buffer
    BodySize = size(Data),
    Http = #http{chunk_toread   = Int-BodySize,
                 status         = 200, % we don't care, it has already been logged
                 body_size      = BodySize + Acc},
    {State#state_rcv{session  = Http,
					 ack_done = false, % continue to read data
                     datasize = BodySize +Acc,
                     dyndata  = Cookie},[]}.

%%----------------------------------------------------------------------
%% Func: parse_cookie/1
%% Purpose: parse HTTP's Cookie Header and returns cookie code
%%----------------------------------------------------------------------
parse_cookie(ParsedHeader) ->
	case httpd_util:key1search(ParsedHeader,"set-cookie") of
		undefined ->
			[];
		Cookie ->
			case string:tokens( Cookie, "; ") of 
				[CookieVal |CookieOtherAttrib] ->
					%% FIXME: handle path attribute
					%% several cookies can be set with a different path attribute
					CookieVal ;
				_Other -> % something wrong
					[]
			end
	end.

%%----------------------------------------------------------------------
%% Func: parse_URL/1
%% Returns: #url
%%----------------------------------------------------------------------
parse_URL("https://" ++ String) ->
    parse_URL(host, String, [], #url{scheme=https});
parse_URL("http://" ++ String) ->
    parse_URL(host, String, [], #url{scheme=http}).

%%----------------------------------------------------------------------
%% Func: parse_URL/4 (inspired by yaws_api.erl)
%% Returns: #url record
%%----------------------------------------------------------------------
% parse host
parse_URL(host, [], Acc, URL) -> % no path or port
    URL#url{host=lists:reverse(Acc), path= "/"};
parse_URL(host, [$/|Tail], Acc, URL) -> % path starts here
    parse_URL(path, Tail, "/", URL#url{host=lists:reverse(Acc)});
parse_URL(host, [$:|Tail], Acc, URL) -> % port starts here
    parse_URL(port, Tail, [], URL#url{host=lists:reverse(Acc)});
parse_URL(host, [H|Tail], Acc, URL) ->
    parse_URL(host, Tail, [H|Acc], URL);

% parse port
parse_URL(port,[], Acc, URL) ->
    URL#url{port=list_to_integer(lists:reverse(Acc)), path= "/"};
parse_URL(port,[$/|T], Acc, URL) ->
    parse_URL(path, T, "/", URL#url{port=list_to_integer(lists:reverse(Acc))});
parse_URL(port,[H|T], Acc, URL) ->
    parse_URL(port, T, [H|Acc], URL);

% parse path
parse_URL(path,[], Acc, URL) ->
    URL#url{path=lists:reverse(Acc)};
parse_URL(path,[$?|T], Acc, URL) ->
    URL#url{path=lists:reverse(Acc), querypart=T};
parse_URL(path,[H|T], Acc, URL) ->
    parse_URL(path, T, [H|Acc], URL).




%%----------------------------------------------------------------------
%% Func: set_msg/1 or /2 or /3
%% Returns: #message record
%% Purpose:
%% unless specified, the thinktime is an exponential random var.
%%----------------------------------------------------------------------
set_msg(HTTPRequest) ->
	set_msg(HTTPRequest, round(ts_stats:exponential(?messages_intensity))).


%% if the URL is full (http://...), we parse it and get server host,
%% port and scheme from the URL and override the global setup of the
%% server. These informations are stored in the #message record.
set_msg(HTTP=#http_request{url="http" ++ URL}, ThinkTime) -> % full URL
    URLrec = parse_URL("http" ++ URL),
    Path = URLrec#url.path ++ URLrec#url.querypart,
    case URLrec of
        #url{scheme= http, port = P} ->
            case P of 
                undefined ->  Port = 80;
                Val ->        Port = Val
            end,
            set_msg(HTTP#http_request{url=Path},
                    ThinkTime,
                    #message{ack  = parse,
                             host = URLrec#url.host,
                             scheme = gen_tcp,
                             port = Port});
        #url{scheme= https, port = P} ->
            case P of 
                undefined ->  Port = 443;
                Val ->        Port = Val
            end,
            set_msg(HTTP#http_request{url=Path},
                    ThinkTime,
                    #message{ack  = parse,
                             host = URLrec#url.host,
                             scheme = ssl,
                             port = Port})
    end;
%
set_msg(HTTPRequest, Think) -> % relative URL, use global host, port and scheme
    set_msg(HTTPRequest, Think, #message{ack = parse}).
            
set_msg(HTTPRequest, 0, Msg) -> % no thinktime, only wait for response
	Msg#message{ thinktime=infinity,
                 param = HTTPRequest };
set_msg(HTTPRequest, Think, Msg) -> % end of a page, wait before the next one
	Msg#message{ endpage   = true,
                 thinktime = Think,
                 param = HTTPRequest }.
