firepad.WebSocketAdapter = (function() {
  var CHECKPOINT_FREQUENCY, TextOperation, WebSocketAdapter, assert, utils;
  window.TextOperation = TextOperation = firepad.TextOperation;
  utils = firepad.utils;
  CHECKPOINT_FREQUENCY = 100;
  WebSocketAdapter = function(channel, userId, userColor) {
    var initial, self;
    self = this;
    self._ready = false;
    self.zombie_ = false;
    self._document = new TextOperation();
    initial = new TextOperation();
    initial.insert(channel.initial);
    self._document = self._document.compose(initial);
    self._revision = channel.revision;
    self.userId = channel.userId;
    self.userColor = channel.userColor;
    if (channel.history.length) {
      channel.history.forEach(function(revision) {
        return self._document = self._document.compose(TextOperation.fromJSON(revision));
      });
    }
    setTimeout(function() {
      self._ready = true;
      self.trigger("ready");
      return self.trigger('operation', self._document);
    }, 0);
    self._send = channel;
    channel.onmessage = function(data) {
      var color, cursor, id, operation, _ref;
      if (data.cursor) {
        _ref = data.cursor, userId = _ref.userId, color = _ref.color, cursor = _ref.cursor;
        return self.trigger('cursor', userId, cursor, color);
      } else {
        id = data.id;
        operation = TextOperation.fromJSON(data.ops);
        return self._handleReceivedOperation(id, operation);
      }
    };
    return self;
  };
  utils.makeEventEmitter(WebSocketAdapter, ['ready', 'cursor', 'operation', 'ack', 'retry']);
  WebSocketAdapter.prototype.dispose = function() {
    this._document = null;
    return this.zombie_ = true;
  };
  WebSocketAdapter.prototype.setUserId = function(userId) {};
  WebSocketAdapter.prototype.isHistoryEmpty = function() {
    assert(this._ready, "Not ready yet.");
    return this._revision === 0;
  };
  /*
  Send operation, retrying on connection failure. Takes an optional callback with signature:
  function(error, committed).
  An exception will be thrown on transaction failure, which should only happen on
  catastrophic failure like a security rule violation.
  */

  WebSocketAdapter.prototype.sendOperation = function(operation, callback) {
    var self;
    self = this;
    if (!this._ready) {
      this.on('ready', function() {
        return self.trigger('retry');
      });
      return;
    }
    assert(this._document.targetLength === operation.baseLength, "sendOperation() called with invalid operation.");
    if (typeof callback === "function") {
      callback(null, true);
    }
    this.sent_ = {
      id: this._revision,
      op: operation
    };
    return self._send({
      id: self._revision,
      ops: operation
    });
  };
  WebSocketAdapter.prototype.sendCursor = function(obj) {
    return this._send({
      broadcast: {
        cursor: {
          cursor: obj,
          userId: this.userId,
          color: this.userColor
        }
      }
    });
  };
  WebSocketAdapter.prototype.setColor = function(color) {
    return this.color_ = color;
  };
  WebSocketAdapter.prototype.getDocument = function() {
    return this._document;
  };
  WebSocketAdapter.prototype.registerCallbacks = function(callbacks) {
    var eventType, _results;
    _results = [];
    for (eventType in callbacks) {
      _results.push(this.on(eventType, callbacks[eventType]));
    }
    return _results;
  };
  WebSocketAdapter.prototype.initializeUserData_ = function() {
    this.sendCursor(this.cursor_ || null);
    return this.setColor(this.color_ || null);
  };
  WebSocketAdapter.prototype.monitorCursors_ = function() {};
  WebSocketAdapter.prototype._handleReceivedOperation = function(revisionId, operation) {
    var triggerRetry;
    this._document = this._document.compose(operation);
    this._revision++;
    if (this.sent_ && revisionId === this.sent_.id) {
      if (this.sent_.op.equals(operation)) {
        this.sent_ = null;
        this.trigger('ack');
      } else {
        triggerRetry = true;
        this.trigger('operation', operation);
      }
    } else {
      this.trigger('operation', operation);
    }
    if (triggerRetry) {
      this.sent_ = null;
      return this.trigger('retry');
    }
  };
  assert = function(b, msg) {
    if (!b) {
      throw new Error(msg || "assertion error");
    }
  };
  return WebSocketAdapter;
})();
