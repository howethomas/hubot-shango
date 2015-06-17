{Adapter,TextMessage,Robot} = require '../../hubot'

url = require 'url'
http = require 'http'
express = require 'express'
Events = require 'events'
Emitter = Events.EventEmitter
Redis = require "redis"
Os = require("os")
Request = require('request')
ReadWriteLock = require('rwlock')
Util = require('util')
Morgan = require('morgan')
BodyParser = require('body-parser');


class Shango extends Adapter

  constructor: (robot) ->
    super(robot)
    @active_numbers = []
    @pending_shango_requests = []

    @ee= new Emitter
    @robot = robot
    @THROTTLE_RATE_MS = 1000
    @SHANGO_SEND_MSG_URL = process.env.SHANGO_SEND_MSG_URL
    # Run a one second loop that checks to see if there are messages to be sent
    # to SHANGO. Wait one second after the request is made to avoid
    # rate throttling issues.
    setInterval(@drain_shango, @THROTTLE_RATE_MS)


  report: (log_string) ->
    @robot.emit("log", log_string)

  drain_shango: () =>
    request = @pending_shango_requests.shift()
    if request?
      @report "Making request to #{request.url}"
      Request.post(
        request.url,
        request.options,
        (error, response, body) =>
          status_message = "Call to #{request.url} #{request.options.from}"
          if !error and response.statusCode == 200
            @report  status_message + " was successful."
          else
            @report  status_message + " failed with #{response.statusCode}:#{response.statusMessage}"
      )

  post_to_shango: (url, options) =>
    request =
      url: url
      options: options
    @pending_shango_requests.push request

  send_shango_message: (to, from, text) ->
    console.log "Sending #{text} to #{to} from #{from}"
    options =
      json: true
      body:
        to: to
        toName: to
        from: from
        fromName: from
        activationType: "SEND_TXT"
        data: text
        timestamp: ""
        attachment: null
    @post_to_shango(@SHANGO_SEND_MSG_URL, options)

  send: (envelope, strings...) ->
    {user, room} = envelope
    user = envelope if not user # pre-2.4.2 style
    from = user.room
    to = user.name
    @send_shango_message(to, from, string) for string in strings

  emote: (envelope, strings...) ->
    @send envelope, "* #{str}" for str in strings

  reply: (envelope, strings...) ->
    strings = strings.map (s) -> "#{envelope.user.name}: #{s}"
    @send envelope, strings...

  run: ->
    self = @
    callback_path = process.env.SHANGO_CALLBACK_PATH or "/shango_callback"
    listen_port = process.env.SHANGO_LISTEN_PORT
    routable_address = process.env.SHANGO_CALLBACK_URL

    callback_url = "#{routable_address}#{callback_path}"
    app = express()
    app.use(Morgan('dev'))
    app.use(BodyParser.json())
    app.use(BodyParser.urlencoded({ extended: true }))

    app.post callback_path, (req, res) =>
      # First, see if this user is in the system.
      # If not, then let's make a new user for this far end.
      #
      res.writeHead 200,     "Content-Type": "text/plain"
      res.write "Message received"
      res.end()

      if req.body?
        user_name = user_id = req.body.remoteNumber
        message_id = req.body.subId
        room_name = req.body.subNumber.replace(/\+/g, '')
        user = @robot.brain.userForId user_name, name: user_name, room: room_name
        inbound_message = new TextMessage user, req.body.info.message, message_id
        @robot.receive inbound_message
        @report "Received #{inbound_message} from #{user_name} bound for #{room_name}"
        return


    server = app.listen(listen_port, "0.0.0.0", ->
      host = server.address().address
      port = server.address().port
      console.log "SHANGO listening locally at http://%s:%s", host, port
      console.log "External URL is #{callback_url}"
      return
    )

    @emit "connected"

exports.use = (robot) ->
  new Shango robot
