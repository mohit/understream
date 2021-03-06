{Readable, Writable, PassThrough, Transform} = require 'stream'
fs     = require('fs')
_      = require 'underscore'
debug  = require('debug') 'us:'
domain = require 'domain'
{EventEmitter} = require 'events'
{is_readable} = require './helpers'

# Adds a listener to an EventEmitter but first bumps the max listeners limit
# for that emitter. The limit is meant to prevent memory leaks, so this should
# only be used when you're sure you're not creating a memory leak. Good luck
# convincing yourself you're safe...
add_listener_unsafe = (emitter, event, listener) ->
  emitter.setMaxListeners emitter._maxListeners + 1
  emitter.addListener event, listener

_.mixin isPlainObject: (obj) -> obj.constructor is {}.constructor

# Wraps a stream's _transform method in a domain, catching any thrown errors
# and re-emitting them from the stream.
domainify = (stream) ->
  if stream instanceof Transform
    dmn = domain.create()
    stream._transform = dmn.bind stream._transform.bind stream
    stream._flush = dmn.bind stream._flush.bind stream if stream._flush?
    dmn.once 'error', (err) ->
      dmn.exit()
      stream.emit 'error', err
    # Use .exit() instead of .dispose() because .dispose() was breaking the
    # tests. Something to look into at some point maybe... (-Jonah)
    add_listener_unsafe stream, 'end', -> dmn.exit()

state_to_string = (state) ->
  if state?
    (state.length or '') + (if state.objectMode then 'o' else 'b')
  else ''

to_report_string = (stream) -> _([
  state_to_string stream._writableState
  stream.constructor.name
  stream._extra_report_string?()
  state_to_string stream._readableState
]).compact().join(' ')

add_reporter = (streams) ->
  report = -> debug _(streams).map(to_report_string).join(' | ')
  interval = setInterval report, 5000
  _(streams).each (stream) -> add_listener_unsafe stream, 'error', -> clearInterval interval
  _(streams).last().on 'finish', -> clearInterval interval

pipeline_of_streams = (streams) ->
  _.flatten _(streams).map (stream) -> stream._pipeline?() or [stream]

pipe_streams_together = (streams...) ->
  return if streams.length < 2
  streams[i].pipe streams[i + 1] for i in [0..streams.length - 2]

# Based on: http://stackoverflow.com/questions/17471659/creating-a-node-js-stream-from-two-piped-streams
# The version there was broken and needed some changes, we just kept the concept of using the 'pipe'
# event and overriding the pipe method
class StreamCombiner extends PassThrough
  constructor: (streams...) ->
    super objectMode: true
    @head = streams[0]
    @tail = streams[streams.length - 1]
    pipe_streams_together streams...
    @on 'pipe', (source) => source.unpipe(@).pipe @head
  pipe: (dest, options) => @tail.pipe dest, options

class ArrayStream extends Readable
  constructor: (@options, @arr, @index=0) ->
    super _(@options).extend objectMode: true
  _read: (size) =>
    debug "_read #{size} #{JSON.stringify @arr[@index]}"
    @push @arr[@index] # Note: push(undefined) signals the end of the stream, so this just works^tm
    @index += 1

class DevNull extends Writable
  constructor: -> super objectMode: true
  _write: (chunk, encoding, cb) -> cb()

module.exports = class Understream
  constructor: (head) ->
    @_defaults = highWaterMark: 20, objectMode: true
    head = new ArrayStream {}, head if _(head).isArray()
    if is_readable head
      @_streams = [head]
    else if not head?
      @_streams = []
    else
      throw new Error 'Understream expects a readable stream, an array, or nothing'

  defaults: (@_defaults) => @
  run: (cb) =>
    throw new Error 'Understream::run requires an error handler' unless _(cb).isFunction()
    # If the callback has arity 2, assume that they want us to aggregate all results in an array and
    # pass that to the callback.
    if cb.length is 2
      result = []
      @batch Infinity
      batch_stream = _(@_streams).last()
      batch_stream.on 'finish', -> result = batch_stream._buffer
    # If the final stream is Readable, attach a dummy writer to receive its output
    # and alleviate pressure in the pipe
    @_streams.push new DevNull() if is_readable _(@_streams).last()
    handler = (err) ->
      if cb.length is 1
        cb err
      else
        cb err, result
    _(@_streams).last().on 'finish', handler
    # Catch any errors thrown emitted by a stream with a handler
    pipeline = pipeline_of_streams @_streams
    add_reporter pipeline
    _.each pipeline, (stream) ->
      domainify stream
      add_listener_unsafe stream, 'error', handler
    debug 'running'
    pipe_streams_together @_streams...
    @
  readable: => # If you want to get out of understream and access the raw stream
    pipe_streams_together @_streams...
    [streams..., last] = @_streams
    _.extend last, _pipeline: -> pipeline_of_streams(streams).concat [last]
  duplex: =>
    _.extend new StreamCombiner(@_streams...), _pipeline: => pipeline_of_streams @_streams
  stream: => @readable() # Just an alias for compatibility purposes
  pipe: (stream_instance) => # If you want to add an instance of a stream to the middle of your understream chain
    @_streams.push stream_instance
    @
  @mixin: (FunctionOrStreamKlass, name=(FunctionOrStreamKlass.name or Readable.name), fn=false) ->
    if _(FunctionOrStreamKlass).isPlainObject() # underscore-style mixins
      @_mixin_by_name klass, name for name, klass of FunctionOrStreamKlass
    else
      @_mixin_by_name FunctionOrStreamKlass, name, fn
  @_mixin_by_name: (FunctionOrStreamKlass, name=(FunctionOrStreamKlass.name or Readable.name), fn=false) ->
    Understream::[name] = (args...) ->
      if fn
        # Allow mixing in of functions like through()
        instance = FunctionOrStreamKlass.apply null, args
      else
        # If this is a class and argument length is < constructor length, prepend defaults to arguments list
        if args.length < FunctionOrStreamKlass.length
          args.unshift _(@_defaults).clone()
        else if args.length is FunctionOrStreamKlass.length
          _(args[0]).defaults @_defaults
        else
          throw new Error "Expected #{FunctionOrStreamKlass.length} or #{FunctionOrStreamKlass.length-1} arguments to #{name}, got #{args.length}"
        instance = new FunctionOrStreamKlass args...
      @pipe instance
      debug 'created', instance.constructor.name, @_streams.length
      @

Understream.mixin _(["#{__dirname}/transforms", "#{__dirname}/readables"]).chain()
  .map (dir) ->
    _(fs.readdirSync(dir)).map (filename) ->
      name = filename.match(/^([^\.]\S+)\.js$/)?[1]
      return unless name # Exclude hidden files
      [name, require("#{dir}/#{filename}")]
  .flatten(true)
  .object().value()
