#!/usr/bin/env coffee

express  = require 'express'
http     = require 'http'
path     = require 'path'
kue      = require 'kue'
redis    = require 'redis'
mongoose = require 'mongoose'
{Schema} = require 'mongoose'
Codo     = require 'codo'

# Production configuration
if process.env.NODE_ENV is 'production'

  # Setup MongoHQ
  mongoose.connect "mongodb://nodejitsu:#{ process.env.MONGODB_PWD }@staff.mongohq.com:10090/nodejitsudb407113725252"

  # Setup RedisToGo
  kue.redis.createClient = ->
    client = redis.createClient 9066, 'gar.redistogo.com', { no_ready_check: true, parser: 'javascript' }
    client.auth process.env.REDIS_PWD
    client

else
  mongoose.connect 'mongodb://localhost/coffeedoc'

CodoProject = mongoose.model 'CodoProject', new Schema
  user:     { type: String }
  project:  { type: String }
  versions: { type: Array }
  updated:  { type: String }

CodoFile = mongoose.model 'CodoFile', new Schema
  path:     { type: String, index: true }
  content:  { type: String }
  live:     { type: Boolean, default: false }

queue = kue.createQueue()

app    = express()
socket = require 'socket.io'

app.engine '.hamlc', require('haml-coffee').__express

app.configure ->
  app.set 'port', 8080

  app.set 'views', __dirname + '/views'
  app.set 'view engine', 'hamlc'
  app.set 'view options', { layout: false }

  app.use express.logger 'dev'
  app.use express.bodyParser()
  app.use express.methodOverride()
  app.use app.router

  app.locals = { codoVersion: Codo.version() }

  # Configure assets
  app.use require('connect-assets')()
  app.use '/images', express.static(path.join(__dirname, 'assets', 'images'))
  app.use express.favicon path.join(__dirname, 'assets', 'images', 'favicon.ico')

# Development settings
app.configure 'development', ->
  app.use express.errorHandler({ dumpExceptions: true, showStack: true })

# Production settings
app.configure 'production', ->
  app.use express.errorHandler()

# Show coffeedoc.info homepage
app.get '/', (req, res) ->
  CodoProject.find {}, (err, docs) ->
    res.render 'index', { projects: docs }

# Serve Codo javascripts
app.get /github\/(.+)\/assets\/codo\.js$/, (req, res) ->
  res.header 'Content-Type', 'application/javascript'
  res.send Codo.script()

# Serve Codo stylesheets
app.get /github\/(.+)\/assets\/codo\.css$/, (req, res) ->
  res.header 'Content-Type', 'text/css'
  res.send Codo.style()

# Redirect to first version
app.get '/github/:user/:project', (req, res) ->
  user = req.params.user
  project = req.params.project

  CodoProject.findOne { user: user, project: project }, (err, doc) ->
    throw err if err

    if doc
      res.redirect "/github/#{ user }/#{ project }/#{ doc.versions.shift() }/"
    else
      res.send 404

# Show Codo generated files
app.get /github\/(.+)$/, (req, res) ->
  path = req.params[0]

  # Provide index.html functionality
  unless /(\.html|\.js|\.css)$/.test path
    if /\/$/.test path
      path += 'index.html'
    else
      return res.redirect "/github/#{ path }/"

  # Detect content type
  switch path
    when /\/.js$/ then res.header 'Content-Type', 'application/javascript'
    when /\/.css$/ then res.header 'Content-Type', 'text/css'
    when /\/.html$/ then res.header 'Content-Type', 'text/html'

  # Locate Codo file resource
  CodoFile.findOne { path: path, live: true }, (err, doc) ->
    throw err if err

    if doc
      res.send doc.content
    else
      res.send 404

# Github checkout hook
app.post '/checkout', (req, res) ->
  payload = JSON.parse req.param('payload')

  unless payload.repository.private
    url = payload.repository.url
    commit = 'master'

    console.log "Enque new GitHub checkout for repository #{ url } (#{ commit })"

    queue.create('codo', {
      title: "Generate Codo documentation for repository at #{ url } (#{ commit })"
      url: url
      commit: commit
    }).attempts(3).save()

  res.send 'OK'

# Start the express server
server = http.createServer(app).listen app.get('port'), ->
  console.log 'Express server listening on port %d in %s mode', app.get('port'), app.settings.env

io = socket.listen server
io.sockets.on 'connection', (socket) ->

  # Checkout a new project
  #
  socket.on 'checkout', (data) ->
    job = queue.create('checkout', {
      title: "Generate Codo documentation for repository at #{ data.url } (#{ data.commit })"
      url: data.url
      commit: data.commit || 'master'
    }).attempts(3).save()

    job.on 'progress', (progress) ->
      socket.emit 'progress', { progress: progress }

    job.on 'failed', ->
      socket.emit 'failed'

    job.on 'complete', ->
      github = /^(?:https?|git):\/\/(?:www\.?)?github\.com\/([^\s/]+)\/([^\s/]+?)(?:\.git)?\/?$/
      [url, user, project] = job.data.url.match github
      commit = data.commit || 'master'

      socket.emit 'complete', { url: "/github/#{ user }/#{ project }/#{ commit }/" }
