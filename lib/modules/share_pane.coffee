randomstring = require 'randomstring'
Marker = null
GrammarSync = null
chunkString = null

{CompositeDisposable, Range, Emitter} = require 'atom'
_ = require 'underscore'
$ = require 'jquery'

module.exports =
class SharePane

  @all: []

  @globalEmitter: new Emitter

  @id: (id) -> _.findWhere(@all,{id: id})
  @each: (fn) -> _.each(@all, fn)
  @any: (fn)-> _.any(@all, fn)

  constructor: (options) ->
    _.extend(@, options)
    if @editor.constructor.name isnt "TextEditor" then throw("editor is of type #{@editor.constructor.name}")
    @buffer = @editor.buffer
    if !@buffer then throw("buffer is nil. editor: #{@editor}")

    @id ?= randomstring.generate(6)
    @triggerPush = true
    @timeouts = []
    @events = []

    @editorListeners = new CompositeDisposable

    atom.views.getView(@editor).setAttribute('id', 'AtomPair')

    Marker = require './marker'
    GrammarSync = require './grammar_sync'
    chunkString = require '../helpers/chunk-string'

    _.extend(@, Marker, GrammarSync)
    @constructor.all.push(@)
    @subscribe()
    @activate()

  subscribe: ->
    channelName = "presence-session-#{@sessionId}-#{@id}"
    @channel = @pusher.subscribe(channelName)
    @connected = true

  activate: ->
    @channel.bind 'client-grammar-sync', (syntax) =>
      grammar = atom.grammars.grammarForScopeName(syntax)
      @editor.setGrammar(grammar)

    @channel.bind 'client-share-whole-file', (file) =>
      @withoutTrigger => @buffer.setText(file)

    @channel.bind 'client-share-partial-file', (chunk) =>
      @withoutTrigger => @buffer.append(chunk)

    @channel.bind 'client-change', (events) =>
      _.each events, (event) =>
        @changeBuffer(event) if event.eventType is 'buffer-change'
        if event.eventType is 'buffer-selection'
          @updateCollaboratorMarker(event)

    @editorListeners.add @listenToBufferChanges()
    @editorListeners.add @syncSelectionRange()
    @editorListeners.add @syncGrammars()

    @listenForDestruction()

  setTabTitle: ->
    tab = @getTab()
    tab.itemTitle.innerText = @title

  persistTabTitle: ->
    atom.workspace.onDidOpen =>
      console.log 'new added', @title
      @setTabTitle()

  disconnect: ->
    @channel.unsubscribe()
    @editorListeners.dispose()
    @connected = false
    atom.views.getView(@editor)?.removeAttribute('id')
    $('.atom-pair-active-icon').remove()
    @editor = @buffer = null
    @constructor.globalEmitter.emit('disconnected')

  listenForDestruction: ->
    # TODO: MAKE THIS SPECIFIC TO THIS SHAREPANE
    @editorListeners.add @buffer.onDidDestroy => @disconnect()
    @editorListeners.add @editor.onDidDestroy => @disconnect()

  withoutTrigger: (callback) ->
    @triggerPush = false
    callback()
    @triggerPush = true

  listenToBufferChanges: ->
    @buffer.onDidChange (event) =>
      return unless @triggerPush

      if event.newText is event.oldText and _.isEqual(event.oldRange, event.newRange)
        return

      if !(event.newText is "\n") and (event.newText.length is 0)
        changeType = 'deletion'
        event = {oldRange: event.oldRange}
      else if event.oldRange.containsRange(event.newRange) or event.newRange.containsRange(event.oldRange)
        changeType = 'substitution'
        event = {oldRange: event.oldRange, newRange: event.newRange, newText: event.newText}
      else
        changeType = 'insertion'
        event  = {newRange: event.newRange, newText: event.newText}

      if event.newText and event.newText.length > 800
        @shareFile()
      else
        event = {changeType: changeType, event: event, colour: @markerColour, eventType: 'buffer-change'}
        @queue.add(@channel.name, 'client-change', [event])

  changeBuffer: (data) ->
    if data.event.newRange then newRange = Range.fromObject(data.event.newRange)
    if data.event.oldRange then oldRange = Range.fromObject(data.event.oldRange)
    if data.event.newText then newText = data.event.newText

    @withoutTrigger =>

      @clearMarkers(data.colour)

      switch data.changeType
        when 'deletion'
          @buffer.delete oldRange
          actionArea = oldRange.start
        when 'substitution'
          @buffer.setTextInRange oldRange, newText
          actionArea = oldRange.start
        else
          @buffer.insert newRange.start, newText
          actionArea = newRange.start

      @editor.scrollToBufferPosition(actionArea)
      @addMarker(actionArea.toArray()[0], data.colour)
      @setActiveIcon(data.colour)

  setActiveIcon: (colour)->
    $('.atom-pair-active-icon').remove()
    tab = @getTab()
    icon = $("<i class=\"icon icon-pencil atom-pair-active-icon\" style=\"color: #{colour}\"></i>")
    tab.itemTitle.appendChild(icon[0])

  getTab: ->
    tabs = $('li[is="tabs-tab"]')
    tab = (t for t in tabs when t.item.id is @editor.id)[0]
    tab

  syncSelectionRange: ->
    @editor.onDidChangeSelectionRange (event) =>
      rows = event.newBufferRange.getRows()
      return unless rows.length > 1
      @events.push {eventType: 'buffer-selection', colour: @markerColour, rows: rows}

  shareFile: ->
    currentFile = @buffer.getText()
    return if currentFile.length is 0

    if currentFile.length < 950
      @queue.add(@channel.name, 'client-share-whole-file', currentFile)
    else
      chunks = chunkString(currentFile, 950)
      _.each chunks, (chunk, index) => @queue.add @channel.name, 'client-share-partial-file', chunk
