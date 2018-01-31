local Peer = require "prailude.peer"
local log = require "prailude.log"
local bus = require "prailude.bus"
local config = require "prailude.config"
local Timer = require "prailude.util.timer"
local DB = require "prailude.db"
local Frontier = require "prailude.frontier"
--local Account = require "prailude.account"
local Message = require "prailude.message"
local Block = require "prailude.block"

local uv = require "luv"
local mm = require "mm"
local coroutine = require "prailude.util.coroutine"

local Rainet = {}

local function keepalive()
  --bootstrap
  
  local function parse_bootstrap_peer(peer_string)
    local peer_name, peer_port
    if type(peer_string) == "string" then
      peer_name, peer_port = peer_string:match("^(.*):(%d+)$")
      if not peer_name then
        peer_name, peer_port = peer_string, 7075
      else
        peer_port = tonumber(peer_port)
      end
    else
      peer_name, peer_port = peer_string[1] or peer_string.name or peer_string.host, peer_string[2] or peer_string.port
    end
    return peer_name, peer_port
  end
  
  bus.sub("run", function()
    local keepalive_msg = Message.new("keepalive", {peers = {}})
    for _, preconfd_peer in pairs(config.node.preconfigured_peers) do
      local peer_name, peer_port = parse_bootstrap_peer(preconfd_peer)
      local addrinfo = uv.getaddrinfo(peer_name, nil, {socktype="dgram", protocol="packet"})
      for _, addrinfo_entry in ipairs(addrinfo) do
        local peer = Peer.get(addrinfo_entry.addr, peer_port)
        peer:send(keepalive_msg)
      end
    end
  end)
  
  --keepalive parsing and response
  bus.sub("message:receive:keepalive", function(ok, msg, peer)
    if not ok then
      return log:warning("rainet: message:receive:keepalive failed from peer %s: %s", peer, msg)
    end
    peer:update_timestamp("keepalive_received")
    local inpeer
    local now = os.time()
    local keepalive_cutoff = now - Peer.keepalive_interval
    if (peer.last_keepalive_sent or 0) < keepalive_cutoff then
      peer:send(Message.new("keepalive", {peers = Peer.get8(peer)}))
    end
    for _, peer_data in ipairs(msg.peers) do
      inpeer = Peer.get(peer_data)
      if (inpeer.last_keepalive_sent or 0) < keepalive_cutoff then
        inpeer:send(Message.new("keepalive", {peers = Peer.get8(inpeer)}))
      end
    end
  end)
  
  --periodic keepalive checks
  Timer.interval(Peer.keepalive_interval * 1000, function()
    local ping_these_peers = Peer.get_active_needing_keepalive()
    for _, peer in pairs(ping_these_peers) do
      peer:send(Message.new("keepalive", {peers = Peer.get8(peer)}))
    end
  end)
end


local function handle_blocks()
  local function check_block(block, peer)
    local ok, err = block:verify()
    if not ok then
      log:debug("server: got block that failed verification (%s) from %s", err, tostring(peer))
    else
      return true
    end
  end
  bus.sub("message:receive:publish", function(ok, msg, peer)
    if not ok then
      return log:warning("rainet: message:receive:publish from %s failed: %s", peer, msg)
    end
    local block = Block.new(msg.block_type, msg.block)
    check_block(block, peer)
  end)
  bus.sub("message:receive:confirm_req", function(ok, msg, peer)
    if not ok then
      return log:warning("rainet: message:receive:confirm_req from %s failed: %s", peer, msg)
    end
    local block = Block.new(msg.block_type, msg.block)
    check_block(block, peer)
  end)
  bus.sub("message:receive:confirm_ack", function(ok, msg, peer)
    if not ok then
      return log:warning("rainet: message:receive:confirm_ack from %s failed: %s", peer, msg)
    end
    local block = Block.new(msg.block_type, msg.block)
    check_block(block, peer)
  end)
end

function Rainet.initialize()
  --local initial_peers = {}
  keepalive()
  handle_blocks()
end

function Rainet.bootstrap()
  return coroutine.wrap(function()
    local frontiers = Rainet.fetch_frontiers()
    
    for _, frontier in pairs(frontiers) do
      Rainet.bulk_pull_accounts(frontier)
    end
    
    --then do something else
  end)()
end

function Rainet.bulk_pull_accounts(frontier)
  local min_speed = 1000 --blocks/sec
  local active_peers = {}
  local frontier_size = #frontier
  
  local getpeer; do
    local fastpeers = {}
    getpeer = function()
      if good_frontier_requests < min_good_frontier_requests then
        local peer = table.remove(fastpeers)
        if not peer then
          fastpeers = Peer.get_fastest_ping(500)
          return table.remove(fastpeers)
        else
          return peer
        end
      else
        --the work is done. stop all active peers
        for peer, _ in pairs(active_peers) do
          if peer.tcp then
            peer.tcp:stop("frontier fetch finished")
          end
        end
        return nil
      end
    end
  end
  
  local ok, failed, errs = coroutine.workpool({
    work = frontier,
    retry = 4,
    progress = function(active_workers, work_done, _, work_failed)
      local bus_data = {
        complete = false,
        active_peers = active_peers,
        frontier_size = frontier_size,
        accounts_fetched = #work_done,
        accounts_failed = #work_failed
      }
      log:debug("bulk pull: using %i workers, finished %i of %i accounts [%3.2f] (%i failed)", active_workers, #work_done, frontier_size, 100 * #work_done / frontier_size, #work_failed)
    end,
    worker = function(frontier)
      
      
      
      local peer = getpeer()
      active_peers[peer] = {}
      
      
      
      active_peers[peer]=nil
    end
  })
  
end

function Rainet.fetch_frontiers()
  local min_frontiers_per_sec = 200
  local min_good_frontier_requests = 3
  
  local good_frontier_requests = 0
  local largest_frontier_pull_size = tonumber(DB.kv.get("largest_frontier_pull") or 0)
  local active_peers = {}
  local frontiers_set, failed, errs = coroutine.workpool({
    work = (function()
      local fastpeers = {}
      return function()
        if good_frontier_requests < min_good_frontier_requests then
          local peer = table.remove(fastpeers)
          if not peer then
            fastpeers = Peer.get_fastest_ping(100)
            return table.remove(fastpeers)
          else
            return peer
          end
        else
          --the work is done. stop all active peers
          for peer, _ in pairs(active_peers) do
            if peer.tcp then
              peer.tcp:stop("frontier fetch finished")
            end
          end
          return nil
        end
      end
    end)(),
    retry = 0,
    progress = (function()
      local last_failed_peer = 0
      return function(active_workers, work_done, _, peers_failed, peers_failed_err)
        local bus_data = {
          complete = false,
          frontier_requests_completed = #work_done,
          active_peers = active_peers,
          failed_peers = {}
        }
        good_frontier_requests = #work_done
        log:debug("frontiers: downloading from %i peers. (%i/%i complete) (%i failed)", active_workers, #work_done, min_good_frontier_requests, #peers_failed)
        for peer, stats in pairs(active_peers) do
          log:debug("frontiers: %5d/sec frontiers (%7d total) [%5.2f%%] from %s", stats.rate or 0, (stats.total or 0), (stats.progress or 0) * 100, peer)
        end
        while last_failed_peer <= #peers_failed do
          local failed_peer = peers_failed[last_failed_peer]
          local failed_peer_error = peers_failed_err[last_failed_peer]
          log:debug("frontiers:   pull failed from %s: %s", failed_peer, failed_peer_error)
          last_failed_peer = last_failed_peer + 1
          bus_data.failed_peers[failed_peer] = failed_peer_error
        end
        bus:pub("fetch_frontiers:progress", bus_data)
      end
    end)(),
    worker = function(peer)
      local frontier_pull_size_estimated = false
      local times_below_min_rate = 0
      local prev_frontiers_count = 0
      --log:debug("bootstrap: starting frontier pull from %s", peer)
      
      active_peers[peer] = {}
      local frontiers, err = Frontier.fetch(peer, function(frontiers_so_far, progress)
        --watchdog checker for frontier fetch progress
        local frontiers_per_sec = #frontiers_so_far - prev_frontiers_count
        prev_frontiers_count = #frontiers_so_far
        if frontiers_per_sec < min_frontiers_per_sec then
          --too slow
          times_below_min_rate = times_below_min_rate + 1
          if times_below_min_rate > 4 then
            return false, ("too slow (%i frontiers/sec)"):format(frontiers_per_sec)
          end
        elseif progress > 0.2 and not frontier_pull_size_estimated then
          --is this pull going to be too small (i.e. from an unsynced node)?
          frontier_pull_size_estimated = true
          if #frontiers_so_far * 1/progress < 0.8 * largest_frontier_pull_size then
            --too small
            return false, ("frontier is too small (circa %.0f, expected %.0f)"):format(#frontiers_so_far * 1/progress, largest_frontier_pull_size)
          end
        end
        --track statistics
        active_peers[peer].rate = frontiers_per_sec
        active_peers[peer].total = #frontiers_so_far
        active_peers[peer].progress = progress
        return true
      end)
      active_peers[peer]=nil
      return frontiers, err
    end
  })
  bus:pub("fetch_frontiers:progress", {
    complete = true,
    frontier_requests_completed = #frontiers_set
  })
  
  return frontiers_set, failed, errs
end

return Rainet
