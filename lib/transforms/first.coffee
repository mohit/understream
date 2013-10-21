{Transform} = require 'stream'

module.exports = class First extends Transform
  constructor: (stream_opts, @first=1) ->
    super stream_opts
    @seen = 0
  _transform: (chunk, encoding, cb) =>
    @seen++
    if @seen > @first
      @push null
      return
    cb null, chunk
