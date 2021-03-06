{Transform} = require 'stream'
_      = require 'underscore'
debug  = require('debug') 'us:each'

module.exports = class Each extends Transform
  constructor: (@stream_opts, @options) ->
    super @stream_opts
    @options = { fn: @options } if _(@options).isFunction()
    @options._async = @options.fn.length is 2
  _transform: (chunk, encoding, cb) =>
    if @options._async
      @options.fn chunk, (err) =>
        return cb err if err?
        @push chunk
        cb()
    else
      @options.fn chunk
      @push chunk
      cb()
