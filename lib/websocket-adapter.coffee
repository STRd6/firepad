firepad.WebSocketAdapter = do ->
  window.TextOperation = TextOperation = firepad.TextOperation
  utils = firepad.utils

  # Save a checkpoint every 100 edits.
  CHECKPOINT_FREQUENCY = 100

  WebSocketAdapter = (channel, userId, userColor) ->
    self = this

    self._ready = false
    self.zombie_ = false

    # We store the current document state as a TextOperation so we can write checkpoints to Firebase occasionally.
    # TODO: Consider more efficient ways to do this. (composing text operations is ~linear in the length of the document).
    self._document = new TextOperation()

    initial = new TextOperation()
    initial.insert(channel.initial)

    self._document = self._document.compose(initial)
    self._revision = channel.revision

    self.userId = channel.userId
    self.userColor = channel.userColor

    if channel.history.length
      # NOTE: We are not and should not update the revision id here
      channel.history.forEach (revision) ->
        self._document = self._document.compose(TextOperation.fromJSON(revision))

    setTimeout ->
      self._ready = true
      self.trigger("ready")

      self.trigger('operation', self._document)
    , 0

    self._send = channel

    channel.onmessage = (data) ->
      if data.cursor
        {userId, color, cursor} = data.cursor
        self.trigger('cursor', userId, cursor, color)
      else
        id = data.id
        operation = TextOperation.fromJSON(data.ops)

        self._handleReceivedOperation(id, operation)

    return self

  utils.makeEventEmitter(WebSocketAdapter, ['ready', 'cursor', 'operation', 'ack', 'retry'])

  WebSocketAdapter.prototype.dispose = ->
    this._document = null
    this.zombie_ = true

  WebSocketAdapter.prototype.setUserId = (userId) ->
    return # TODO

  WebSocketAdapter.prototype.isHistoryEmpty = ->
    assert(this._ready, "Not ready yet.")
    return this._revision is 0;

  ###
  Send operation, retrying on connection failure. Takes an optional callback with signature:
  function(error, committed).
  An exception will be thrown on transaction failure, which should only happen on
  catastrophic failure like a security rule violation.
  ###
  WebSocketAdapter.prototype.sendOperation = (operation, callback) ->
    self = this

    # If we're not ready yet, do nothing right now, and trigger a retry when we're ready.
    if !this._ready
      this.on 'ready', ->
        self.trigger('retry')

      return

    # Sanity check that this operation is valid.
    assert(this._document.targetLength is operation.baseLength, "sendOperation() called with invalid operation.")

    callback?(null, true)

    this.sent_ = { id: this._revision, op: operation }
    self._send
      id: self._revision
      ops: operation

  WebSocketAdapter.prototype.sendCursor = (obj) ->
    this._send
      broadcast:
        cursor:
          cursor: obj
          userId: this.userId
          color: this.userColor

  WebSocketAdapter.prototype.setColor = (color) ->
    # TODO: this.userRef_.child('color').set(color)
    this.color_ = color

  WebSocketAdapter.prototype.getDocument = ->
    return this._document

  WebSocketAdapter.prototype.registerCallbacks = (callbacks) ->
    for eventType of callbacks
      this.on(eventType, callbacks[eventType])

  WebSocketAdapter.prototype.initializeUserData_ = () ->
    # this.userRef_.child('cursor').onDisconnect().remove();
    # this.userRef_.child('color').onDisconnect().remove();

    this.sendCursor(this.cursor_ || null)
    this.setColor(this.color_ || null)

  WebSocketAdapter.prototype.monitorCursors_ = () ->
    return # TODO


  WebSocketAdapter.prototype._handleReceivedOperation = (revisionId, operation) ->
    this._document = this._document.compose(operation)
    this._revision++

    if (this.sent_ && revisionId is this.sent_.id)
      # We have an outstanding change at this revision id.
      if (this.sent_.op.equals(operation))
        # This is our change; it succeeded.
        this.sent_ = null
        this.trigger('ack')
      else
        # our op failed.  Trigger a retry after we're done catching up on any incoming ops.
        triggerRetry = true
        this.trigger('operation', operation)
    else
      this.trigger('operation', operation)

    if (triggerRetry)
      this.sent_ = null
      this.trigger('retry')

  # Throws an error if the first argument is falsy. Useful for debugging.
  assert = (b, msg) ->
    if !b
      throw new Error(msg || "assertion error")

  return WebSocketAdapter
