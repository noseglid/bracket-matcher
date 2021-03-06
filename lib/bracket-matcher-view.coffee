_ = require 'underscore-plus'
{Range, View} = require 'atom'
TagFinder = require './tag-finder'

startPairMatches =
  '(': ')'
  '[': ']'
  '{': '}'

endPairMatches =
  ')': '('
  ']': '['
  '}': '{'

pairRegexes = {}
for startPair, endPair of startPairMatches
  pairRegexes[startPair] = new RegExp("[#{_.escapeRegExp(startPair + endPair)}]", 'g')

module.exports =
class BracketMatcherView extends View
  @content: ->
    @div =>
      @div class: 'bracket-matcher', style: 'display: none', outlet: 'startView'
      @div class: 'bracket-matcher', style: 'display: none', outlet: 'endView'

  initialize: (@editorView) ->
    {@editor} = @editorView
    @tagFinder = new TagFinder(@editor)
    @pairHighlighted = false
    @updateHighlights = false

    @subscribe atom.config.observe 'editor.fontSize', =>
      @updateMatch()

    @subscribe @editor.getBuffer(), 'changed', =>
      @updateHighlights = true

    @subscribe @editor, 'screen-lines-changed', =>
      @updateHighlights = true

    @subscribe @editorView, 'editor:display-updated', =>
      if @updateHighlights
        @updateHighlights = false
        @updateMatch()

    @subscribe @editorView, 'editor:min-width-changed', =>
      @updateHighlights = true if @editor.getSoftWrap()

    @subscribe @editor, 'soft-wrap-changed', =>
      @updateHighlights = true

    @subscribe @editor, 'grammar-changed', =>
      @updateHighlights = true

    @subscribeToCursor()

    @subscribeToCommand @editorView, 'bracket-matcher:go-to-matching-bracket', =>
      @goToMatchingPair()

    @subscribeToCommand @editorView, 'bracket-matcher:go-to-enclosing-bracket', =>
      @goToEnclosingPair()

    @subscribeToCommand @editorView, 'bracket-matcher:select-inside-brackets', =>
      @selectInsidePair()

    @editorView.underlayer.append(this)
    @updateMatch()

  subscribeToCursor: ->
    cursor = @editor.getCursor()
    return unless cursor?

    @subscribe cursor, 'moved', =>
      @updateMatch()

    @subscribe cursor, 'destroyed', =>
      @unsubscribe(cursor)
      @subscribeToCursor()
      @updateMatch() if @editor.isAlive()

  updateMatch: ->
    if @pairHighlighted
      @startView.hide()
      @endView.hide()
    @pairHighlighted = false

    return unless @editor.getSelection().isEmpty()
    return if @editor.isFoldedAtCursorRow()

    {position, currentPair, matchingPair} = @findCurrentPair(startPairMatches)
    if position
      matchPosition = @findMatchingEndPair(position, currentPair, matchingPair)
    else
      {position, currentPair, matchingPair} = @findCurrentPair(endPairMatches)
      if position
        matchPosition = @findMatchingStartPair(position, matchingPair, currentPair)

    if position? and matchPosition?
      @moveStartView([position, position.translate([0, 1])])
      @moveEndView([matchPosition, matchPosition.translate([0, 1])])
      @pairHighlighted = true
    else
      if pair = @tagFinder.findMatchingTags()
        @moveStartView(pair.startRange)
        @moveEndView(pair.endRange)
        @pairHighlighted = true

  findMatchingEndPair: (startPairPosition, startPair, endPair) ->
    scanRange = new Range(startPairPosition.translate([0, 1]), @editor.buffer.getEndPosition())
    endPairPosition = null
    unpairedCount = 0
    @editor.scanInBufferRange pairRegexes[startPair], scanRange, ({match, range, stop}) ->
      switch match[0]
        when startPair
          unpairedCount++
        when endPair
          unpairedCount--
          if unpairedCount < 0
            endPairPosition = range.start
            stop()

    endPairPosition

  findMatchingStartPair: (endPairPosition, startPair, endPair) ->
    scanRange = new Range([0, 0], endPairPosition)
    startPairPosition = null
    unpairedCount = 0
    @editor.backwardsScanInBufferRange pairRegexes[startPair], scanRange, ({match, range, stop}) ->
      switch match[0]
        when startPair
          unpairedCount--
          if unpairedCount < 0
            startPairPosition = range.start
            stop()
        when endPair
          unpairedCount++
    startPairPosition

  findAnyStartPair: (cursorPosition) ->
    scanRange = new Range([0, 0], cursorPosition)
    startPair = _.escapeRegExp(_.keys(startPairMatches).join(''))
    endPair = _.escapeRegExp(_.keys(endPairMatches).join(''))
    combinedRegExp = new RegExp("[#{startPair}#{endPair}]", 'g')
    startPairRegExp = new RegExp("[#{startPair}]", 'g')
    endPairRegExp = new RegExp("[#{endPair}]", 'g')
    startPosition = null
    unpairedCount = 0
    @editor.backwardsScanInBufferRange combinedRegExp, scanRange, ({match, range, stop}) =>
      if match[0].match(endPairRegExp)
        unpairedCount++
      else if match[0].match(startPairRegExp)
        unpairedCount--
        startPosition = range.start
        stop() if unpairedCount < 0
     startPosition

  moveHighlightView: (view, bufferRange) ->
    bufferRange = Range.fromObject(bufferRange)
    view.bufferPosition = bufferRange.start

    startPixelPosition = @editorView.pixelPositionForBufferPosition(bufferRange.start)
    endPixelPosition = @editorView.pixelPositionForBufferPosition(bufferRange.end)

    [element] = view
    element.style.display = 'block'
    element.style.top = "#{startPixelPosition.top}px"
    element.style.left = "#{startPixelPosition.left}px"
    element.style.width = "#{endPixelPosition.left - startPixelPosition.left}px"
    element.style.height = "#{@editorView.lineHeight}px"

  moveStartView: (bufferRange) ->
    @moveHighlightView(@startView, bufferRange)

  moveEndView: (bufferRange) ->
    @moveHighlightView(@endView, bufferRange)

  findCurrentPair: (matches) ->
    position = @editor.getCursorBufferPosition()
    currentPair = @editor.getTextInRange(Range.fromPointWithDelta(position, 0, 1))
    unless matches[currentPair]
      position = position.translate([0, -1])
      currentPair = @editor.getTextInRange(Range.fromPointWithDelta(position, 0, 1))
    if matchingPair = matches[currentPair]
      {position, currentPair, matchingPair}
    else
      {}

  goToMatchingPair: ->
    return @goToEnclosingPair() unless @pairHighlighted
    return unless @editorView.underlayer.isVisible()

    position = @editor.getCursorBufferPosition()
    previousPosition = position.translate([0, -1])
    startPosition = @startView.bufferPosition
    endPosition = @endView.bufferPosition

    if position.isEqual(startPosition)
      @editor.setCursorBufferPosition(endPosition.translate([0, 1]))
    else if previousPosition.isEqual(startPosition)
      @editor.setCursorBufferPosition(endPosition)
    else if position.isEqual(endPosition)
      @editor.setCursorBufferPosition(startPosition.translate([0, 1]))
    else if previousPosition.isEqual(endPosition)
      @editor.setCursorBufferPosition(startPosition)

  goToEnclosingPair: ->
    return if @pairHighlighted
    return unless @editorView.underlayer.isVisible()
    position = @editor.getCursorBufferPosition()
    matchPosition = @findAnyStartPair(position)
    if matchPosition
      @editor.setCursorBufferPosition(matchPosition)

  selectInsidePair: ->
    return unless @editorView.underlayer.isVisible()

    if @pairHighlighted
      startPosition = @startView.bufferPosition
      endPosition = @endView.bufferPosition
    else
      if startPosition = @findAnyStartPair(@editor.getCursorBufferPosition())
        startPair = @editor.getTextInRange(Range.fromPointWithDelta(startPosition, 0, 1))
        endPosition = @findMatchingEndPair(startPosition, startPair, startPairMatches[startPair])

    if startPosition? and endPosition?
      rangeToSelect = new Range(startPosition, endPosition).translate([0, 1], [0, 0])
      @editor.setSelectedBufferRange(rangeToSelect)
