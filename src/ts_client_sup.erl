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

-module(ts_client_sup).
-vc('$Id$ ').
-author('nicolas.niclausse@IDEALX.com').

-behaviour(supervisor).

-include("../include/ts_profile.hrl").

%% External exports
-export([start_link/0, start_child/1]).

%% supervisor callbacks
-export([init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(ServerId) ->
    supervisor:start_child(?MODULE,[ServerId]).

%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok,  {SupFlags,  [ChildSpec]}} |
%%          ignore                          |
%%          {error, Reason}   
%%----------------------------------------------------------------------
init([]) ->
	?PRINTDEBUG2("Starting ~n", ?INFO),
    SupFlags = {simple_one_for_one,1,?restart_sleep},
    ChildSpec = [ 
				  {ts_client,{ts_client, start, []},
				   transient,2000,worker,[ts_client]}
				 ],
    {ok, {SupFlags, ChildSpec}}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

