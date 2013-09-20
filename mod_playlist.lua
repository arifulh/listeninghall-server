local host_session       = prosody.hosts[module.host];
local t_insert, t_remove = table.insert, table.remove;
local st_msg             = require "util.stanza".message;
local st_iq              = require "util.stanza".iq;
local http               = require "net.http";
local json               = require "util.json"; 
local jidutil            = require "util.jid";
local song_queue_xmlns   = "http://listeninghall.com/ns/song#queue";
local song_play_xmlns    = "http://listeninghall.com/ns/song#play";
local song_stop_xmlns    = "http://listeninghall.com/ns/song#stop"
local sync_xmlns         = "http://listeninghall.com/ns/song#sync";
local skip_xmlns         = "http://listeninghall.com/ns/song#skip";
local playlist_xmlns     = "http://listeninghall.com/ns/playlist";

-- Helper function to get playlist from room object. 
-- If playlist does not exist, create it. 
function get_playlist( room ) 
  local playlist = room._data['playlist'];
  if not playlist then
    playlist = {};
    room._data['playlist'] = playlist;
        room._data['svote'] = 0;
  end
  return playlist;
end

-- Helper function to get the room a stanza is addressed to
function get_room( stanza )
  local muc_rooms = host_session.muc and host_session.muc.rooms;
  local room = muc_rooms[stanza.attr.to];
  return room;
end

-- Create song object to be added to playlsit. Everything is parsed from the
-- the JSON response, and the only thing we are adding is a generated unique id.
function create_song( entry ) 
  local uuid_gen = require "util.uuid".generate;
  local song = {
    uuid  = tostring(uuid_gen()),
    sid   = tostring(entry["media$group"]["yt$videoid"]["$t"]),
    slen  = tostring(entry["media$group"]["yt$duration"]["seconds"]),
    thumb = tostring(entry["media$group"]["media$thumbnail"][1]["url"]),
    title = tostring(entry["media$group"]["media$title"]["$t"])
  }
  return song;
end

-- This function contains the primary logic for our syncing mechanim.
-- The basic idea is to take the playlist table, and "start" it. We do 
-- this by looking up the first song object in the list, retrieve the 
-- stored length of that song, and create a timer of that length. When 
-- the timer is up, we remove that song from the playlist, send a signal
-- to all clients notifying them to do the same, and then call play_song
-- again to create a timer for the next song, and so on.
function play_song( playlist, room ) 
  -- If there is nothing in playlist, send stop signal, and return;
  if (#playlist == 0) then 
    local stop_signal = st_msg({ to = "", from = room.jid, type = "groupchat" })
              :tag("song", { xmlns = song_stop_xmlns, type = "stop"})
    room:broadcast_message(stop_signal, false);
    return;
  end;

    -- Clear skip vote history for the room, and each user.
    room._data['svote'] = 0;
    for usr, usrdata in pairs(room._occupants) do
        usrdata.voted = false;
    end 

  -- Create timer, store a reference to the first song object
  local timer = require "util.timer";
  local first = playlist[1];
  
  -- Create "signaling" stanza to send to clients
  local play_signal = st_msg({ to = "", from = room.jid, type = "groupchat" })
              :tag("song", { xmlns = song_play_xmlns, type = "play"})
                :tag("uuid"):text(first["uuid"]):up() 
                :tag("sid"):text(first["sid"]):up()
  
  -- Fire signal to client to play song.
  room:broadcast_message(play_signal, false);
  
  -- Once the signal has been sent, the timer begins. We store the current
  -- time (start time of song), and begin the timer of song length.
  room._data['song_start'] = os.time();
  
  timer.add_task(first["slen"], function()
    -- If there is nothing in playlist, do nothing.
    if #playlist == 0 then return end;
    
    -- The following line accounts for songs that have been skipped.
    -- "first" was a reference to to the first song in the playlist.
    -- If that song was skipped (and thus removed from the playlist), 
    -- the first song in the playlist *now* will be different from our
    -- stored reference. Therefore, we must make sure the timer for
    -- that song (our stored reference) does nothing.
    if first["uuid"] ~= playlist[1]["uuid"] then return end;
    
    -- If the song was not skipped, proceed normally. Remove it,
    -- clear song_start time stamp, and call play_song again to 
    -- start the timer for the next song.
    t_remove(playlist, 1);
    room._data['song_start'] = nil;
    play_song(playlist, room);
  end);
end

-- Validate the youtube id provided. If it is a valid youtube id, 
-- add the song to playlist.
function song_handler( event, song_child )
  local origin, stanza   = event.origin, event.stanza;
  local room             = get_room( stanza );
  local songid           = song_child:get_child("sid"):get_text();
  local url              = "http://gdata.youtube.com/feeds/api/videos/" 
                .. songid .. "?v=2&alt=json";   

  -- HTTP Request JSON data for provided youtube ID
  http.request(url, nil, function( data, code, req )  
    if code == 200 then 
      -- If successful response, decode JSON
      local decoded    = json.decode(data);
      local entry      = decoded["entry"];
      local permission = entry["yt$accessControl"][5]["permission"];
        
      -- If the song is not embeddable, do nothing (return false). 
      if permission ~= "allowed" then return false end;

      -- If the song is valid, create a song object to be added.
      -- Also create a stanza for this new song to be sent to the room.
      local new_song   = create_song(entry);
      local playlist   = get_playlist(room);
      stanza:get_child("song", song_queue_xmlns)
        :tag("uuid"):text(new_song.uuid):up()
        :tag("slen"):text(new_song.slen):up()
        :tag("thumb"):text(new_song.thumb):up()
        :tag("title"):text(new_song.title):up()
        
      -- Insert our new song to the playlist. Broadcast this song
      -- to the room so that clients can "queue" the song on their 
      -- end. Finally, "start" the playlist if it was empty before.
      t_insert(playlist, new_song);
      room:handle_to_room(origin, stanza); 
      if (#playlist == 1) then play_song(playlist, room) end; 
    end
  end)
end

-- Check message for song child element. If it is exists, send it
-- over to song_handler(). Return true so that this message does 
-- not get passed on to the MUC component for further processing.
function check_message( event ) 
  local song_child = event.stanza:get_child("song", song_queue_xmlns);
  if song_child then 
    song_handler(event, song_child);
    return true;
  end;
end

function check_iq( event )
  local request_playlist = event.stanza:get_child("query", playlist_xmlns);
  local request_sync     = event.stanza:get_child("query", sync_xmlns); 
  local request_skip     = event.stanza:get_child("query", skip_xmlns);
  
  if request_playlist then 
    playlist_request_handler(event);
    return true;
  end;
  if request_sync then 
    sync_handler(event);
    return true;
  end;
  if request_skip then
    skip_handler(event);
    return true;
  end
end

-- Grabs the playlist from specified room, and builds a result
-- stanza including every song in the playlist. 
function playlist_request_handler( event )
  local origin, stanza = event.origin, event.stanza;
  local room           = get_room(stanza);
  local playlist       = get_playlist(room);
  local result         = st_iq({ type = 'result', id = stanza.attr.id, 
                   from = room.jid, to = stanza.attr.from })
                              :tag("playlist", { xmlns = playlist_xmlns });
  -- Add songs to result stanza
  for i=1,#playlist,1 do  
    result:tag("song")
        :tag("sid"):text(playlist[i].sid):up()
        :tag("uuid"):text(playlist[i].uuid):up()
        :tag("slen"):text(playlist[i].slen):up()
        :tag("thumb"):text(playlist[i].thumb):up()
        :tag("title"):text(playlist[i].title):up()
      :up()
  end
  origin.send(result);
end

function sync_handler( event )
  local origin, stanza = event.origin, event.stanza;
  local room           = get_room(event.stanza);
  local playlist       = get_playlist(room);
    
    -- Return if playlist is empty
    if (#playlist == 0) then return end;

  local song_start     = room._data['song_start'];
  local first          = playlist[1];
  -- Default sync values if there is no song playing.
  local elapsed        = -1;
  local sid            = "none";
  local uuid           = "none"
  
  -- If there is a song playing, song_start will contain the the time stamp 
  -- for when that song started playing. Find the difference from the start 
  -- time and the time now to determine time elapsed.
  if song_start then
    elapsed = (os.time() - song_start);  
    sid     = first["sid"];
    uuid    = first["uuid"];  
  end
  
  -- Build and send result stanza with sync information           
  origin.send(st_iq({ type = 'result', id = stanza.attr.id, 
               from = room.jid, to = stanza.attr.from })
          :tag('sync', { xmlns = sync_xmlns })
            :tag('sid'):text(sid):up()
            :tag('uuid'):text(uuid):up()
            :tag('elapsed'):text(tostring(elapsed)));
end

-- Skip the cuurent song if over half the room votes to skip
function skip_handler( event )
    -- Get room, and playlist, return if the playlist is empty
  local room     = get_room(event.stanza);
  local playlist = get_playlist(room);
    if (#playlist == 0) then return end;

    -- Get user data for this user
    local from     = event.stanza.attr.from;
    local nick     = room._jid_nick[from];
    local usr      = room._occupants[nick];
    local voted    = usr.voted;

    -- If this user has not voted yet, count his/her vote.
    -- Increment the room's vote tally counter, and mark
    -- that this user has voted.
    if (voted == nil or voted == false) then 
        usr.voted = true;
        room._data['svote'] = room._data['svote'] + 1;
    -- Otherwise, return if user already voted.
    else return end; 
    
    -- Store current vote tally.
    local tally = room._data['svote'];

    -- Get total number of users in the room currently. This 
    -- is a key, value map, we have to loop to get the total.
    local total = 0;
    for usr in pairs(room._occupants) do
        total = total + 1;
    end
    
    -- Determine vote percentage, and skip signal if
    -- over 50% Remove current song, play the next song.
    local percent = (tally/total)*100;
    if (percent >= 50) then 
      t_remove(playlist,1);
      play_song(playlist, room);
    end     
end

module:hook("message/bare", check_message);
module:hook("iq/bare", check_iq);
















