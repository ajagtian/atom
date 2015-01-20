_ = require 'underscore-plus'
React = require 'react-atom-fork'
{div, span} = require 'reactionary-atom-fork'
{debounce, isEqual, isEqualForProperties, multiplyString, toArray} = require 'underscore-plus'
{$$} = require 'space-pen'

Decoration = require './decoration'
CursorsComponent = require './cursors-component'
HighlightsComponent = require './highlights-component'
OverlayManager = require './overlay-manager'

DummyLineNode = $$(-> @div className: 'line', style: 'position: absolute; visibility: hidden;', => @span 'x')[0]
AcceptFilter = {acceptNode: -> NodeFilter.FILTER_ACCEPT}
WrapperDiv = document.createElement('div')

module.exports =
LinesComponent = React.createClass
  displayName: 'LinesComponent'

  render: ->
    {performedInitialMeasurement, cursorBlinkPeriod, cursorBlinkResumeDelay} = @props

    if performedInitialMeasurement
      {editor, overlayDecorations, highlightDecorations, scrollHeight, scrollWidth, placeholderText, backgroundColor} = @props
      {lineHeightInPixels, defaultCharWidth, scrollViewHeight, scopedCharacterWidthsChangeCount} = @props
      {scrollTop, scrollLeft, cursorPixelRects} = @props
      style =
        height: Math.max(scrollHeight, scrollViewHeight)
        width: scrollWidth
        WebkitTransform: @getTransform()
        backgroundColor: if editor.isMini() then null else backgroundColor

    div {className: 'lines', style},
      div className: 'placeholder-text', placeholderText if placeholderText?

      CursorsComponent {
        cursorPixelRects, cursorBlinkPeriod, cursorBlinkResumeDelay, lineHeightInPixels,
        defaultCharWidth, scopedCharacterWidthsChangeCount, performedInitialMeasurement
      }

      HighlightsComponent {
        editor, highlightDecorations, lineHeightInPixels, defaultCharWidth,
        scopedCharacterWidthsChangeCount, performedInitialMeasurement
      }

  getTransform: ->
    {scrollTop, scrollLeft, useHardwareAcceleration} = @props

    if useHardwareAcceleration
      "translate3d(#{-scrollLeft}px, #{-scrollTop}px, 0px)"
    else
      "translate(#{-scrollLeft}px, #{-scrollTop}px)"

  componentWillMount: ->
    @measuredLines = new Set
    @lineNodesByLineId = {}
    @screenRowsByLineId = {}
    @lineIdsByScreenRow = {}
    @renderedDecorationsByLineId = {}

  componentDidMount: ->
    if @props.useShadowDOM
      insertionPoint = document.createElement('content')
      insertionPoint.setAttribute('select', '.overlayer')
      @getDOMNode().appendChild(insertionPoint)

      insertionPoint = document.createElement('content')
      insertionPoint.setAttribute('select', 'atom-overlay')
      @overlayManager = new OverlayManager(@props.hostElement)
      @getDOMNode().appendChild(insertionPoint)
    else
      @overlayManager = new OverlayManager(@getDOMNode())

  componentDidUpdate: (prevProps) ->
    {visible, scrollingVertically, performedInitialMeasurement} = @props
    return unless performedInitialMeasurement

    unless isEqualForProperties(prevProps, @props, 'showIndentGuide')
      @removeLineNodes()

    @updateLineNodes(@props.lineWidth isnt prevProps.lineWidth)

    @measureCharactersInNewLines() if visible and not scrollingVertically

    @overlayManager?.render(@props)

  clearScreenRowCaches: ->
    @screenRowsByLineId = {}
    @lineIdsByScreenRow = {}

  removeLineNodes: ->
    @removeLineNode(id) for id of @oldState

  removeLineNode: (id) ->
    @lineNodesByLineId[id].remove()
    delete @lineNodesByLineId[id]
    delete @lineIdsByScreenRow[@screenRowsByLineId[id]]
    delete @screenRowsByLineId[id]
    delete @oldState[id]

  updateLineNodes: ->
    {presenter, lineDecorations, mouseWheelScreenRow} = @props
    @newState = presenter?.state.lines

    return unless @newState?
    @oldState ?= {}
    @lineNodesByLineId ?= {}

    for id of @oldState
      unless @newState.hasOwnProperty(id) or mouseWheelScreenRow is @screenRowsByLineId[id]
        @removeLineNode(id)

    newLineIds = null
    newLinesHTML = null

    for id, lineState of @newState
      if @oldState.hasOwnProperty(id)
        @updateLineNode(id)
      else
        newLineIds ?= []
        newLinesHTML ?= ""
        newLineIds.push(id)
        newLinesHTML += @buildLineHTML(id)
        @screenRowsByLineId[id] = lineState.screenRow
        @lineIdsByScreenRow[lineState.screenRow] = id
      @oldState[id] = _.clone(lineState)

      @renderedDecorationsByLineId[id] = lineDecorations[lineState.screenRow]

    return unless newLineIds?

    WrapperDiv.innerHTML = newLinesHTML
    newLineNodes = toArray(WrapperDiv.children)
    node = @getDOMNode()
    for id, i in newLineIds
      lineNode = newLineNodes[i]
      @lineNodesByLineId[id] = lineNode
      node.appendChild(lineNode)

  buildLineHTML: (id) ->
    {presenter, showIndentGuide, lineHeightInPixels, lineDecorations} = @props
    {screenRow, tokens, text, top, width, lineEnding, fold, isSoftWrapped, indentLevel} = @newState[id]

    classes = ''
    if decorations = lineDecorations[screenRow]
      for decorationId, decoration of decorations
        if Decoration.isType(decoration, 'line')
          classes += decoration.class + ' '
    classes += 'line'

    lineHTML = "<div class=\"#{classes}\" style=\"position: absolute; top: #{top}px; width: #{width}px;\" data-screen-row=\"#{screenRow}\">"

    if text is ""
      lineHTML += @buildEmptyLineInnerHTML(id)
    else
      lineHTML += @buildLineInnerHTML(id)

    lineHTML += '<span class="fold-marker"></span>' if fold
    lineHTML += "</div>"
    lineHTML

  buildEmptyLineInnerHTML: (id) ->
    {showIndentGuide} = @props
    {indentLevel, tabLength, endOfLineInvisibles} = @newState[id]

    if showIndentGuide and indentLevel > 0
      invisibleIndex = 0
      lineHTML = ''
      for i in [0...indentLevel]
        lineHTML += "<span class='indent-guide'>"
        for j in [0...tabLength]
          if invisible = endOfLineInvisibles?[invisibleIndex++]
            lineHTML += "<span class='invisible-character'>#{invisible}</span>"
          else
            lineHTML += ' '
        lineHTML += "</span>"

      while invisibleIndex < endOfLineInvisibles?.length
        lineHTML += "<span class='invisible-character'>#{endOfLineInvisibles[invisibleIndex++]}</span>"

      lineHTML
    else
      @buildEndOfLineHTML(id) or '&nbsp;'

  buildLineInnerHTML: (id) ->
    {editor, showIndentGuide} = @props
    {tokens, text} = @newState[id]
    innerHTML = ""

    scopeStack = []
    firstTrailingWhitespacePosition = text.search(/\s*$/)
    lineIsWhitespaceOnly = firstTrailingWhitespacePosition is 0
    for token in tokens
      innerHTML += @updateScopeStack(scopeStack, token.scopes)
      hasIndentGuide = not editor.isMini() and showIndentGuide and (token.hasLeadingWhitespace() or (token.hasTrailingWhitespace() and lineIsWhitespaceOnly))
      innerHTML += token.getValueAsHtml({hasIndentGuide})

    innerHTML += @popScope(scopeStack) while scopeStack.length > 0
    innerHTML += @buildEndOfLineHTML(id)
    innerHTML

  buildEndOfLineHTML: (id) ->
    {endOfLineInvisibles} = @newState[id]

    html = ''
    if endOfLineInvisibles?
      for invisible in endOfLineInvisibles
        html += "<span class='invisible-character'>#{invisible}</span>"
    html

  updateScopeStack: (scopeStack, desiredScopeDescriptor) ->
    html = ""

    # Find a common prefix
    for scope, i in desiredScopeDescriptor
      break unless scopeStack[i] is desiredScopeDescriptor[i]

    # Pop scopeDescriptor until we're at the common prefx
    until scopeStack.length is i
      html += @popScope(scopeStack)

    # Push onto common prefix until scopeStack equals desiredScopeDescriptor
    for j in [i...desiredScopeDescriptor.length]
      html += @pushScope(scopeStack, desiredScopeDescriptor[j])

    html

  popScope: (scopeStack) ->
    scopeStack.pop()
    "</span>"

  pushScope: (scopeStack, scope) ->
    scopeStack.push(scope)
    "<span class=\"#{scope.replace(/\.+/g, ' ')}\">"

  updateLineNode: (id) ->

    {lineHeightInPixels, lineDecorations} = @props
    {screenRow, top, width} = @newState[id]


    lineNode = @lineNodesByLineId[id]

    decorations = lineDecorations[screenRow]
    previousDecorations = @renderedDecorationsByLineId[id]

    if previousDecorations?
      for decorationId, decoration of previousDecorations
        if Decoration.isType(decoration, 'line') and not @hasDecoration(decorations, decoration)
          lineNode.classList.remove(decoration.class)

    if decorations?
      for decorationId, decoration of decorations
        if Decoration.isType(decoration, 'line') and not @hasDecoration(previousDecorations, decoration)
          lineNode.classList.add(decoration.class)

    lineNode.style.width = width + 'px'
    lineNode.style.top = top + 'px'
    lineNode.dataset.screenRow = screenRow
    @screenRowsByLineId[id] = screenRow
    @lineIdsByScreenRow[screenRow] = id

  hasDecoration: (decorations, decoration) ->
    decorations? and decorations[decoration.id] is decoration

  lineNodeForScreenRow: (screenRow) ->
    @lineNodesByLineId[@lineIdsByScreenRow[screenRow]]

  measureLineHeightAndDefaultCharWidth: ->
    node = @getDOMNode()
    node.appendChild(DummyLineNode)
    lineHeightInPixels = DummyLineNode.getBoundingClientRect().height
    charWidth = DummyLineNode.firstChild.getBoundingClientRect().width
    node.removeChild(DummyLineNode)

    {editor, presenter} = @props
    presenter?.setLineHeight(lineHeightInPixels)
    editor.setLineHeightInPixels(lineHeightInPixels)
    presenter?.setBaseCharacterWidth(charWidth)
    editor.setDefaultCharWidth(charWidth)

  remeasureCharacterWidths: ->
    return unless @props.performedInitialMeasurement

    @clearScopedCharWidths()
    @measureCharactersInNewLines()

  measureCharactersInNewLines: ->
    {editor, tokenizedLines, renderedRowRange} = @props
    [visibleStartRow] = renderedRowRange
    node = @getDOMNode()

    editor.batchCharacterMeasurement =>
      for id, lineState of @oldState
        unless @measuredLines.has(id)
          lineNode = @lineNodesByLineId[id]
          @measureCharactersInLine(lineState, lineNode)
      return

  measureCharactersInLine: (tokenizedLine, lineNode) ->
    {editor} = @props
    rangeForMeasurement = null
    iterator = null
    charIndex = 0

    for {value, scopes, hasPairedCharacter} in tokenizedLine.tokens
      charWidths = editor.getScopedCharWidths(scopes)

      valueIndex = 0
      while valueIndex < value.length
        if hasPairedCharacter
          char = value.substr(valueIndex, 2)
          charLength = 2
          valueIndex += 2
        else
          char = value[valueIndex]
          charLength = 1
          valueIndex++

        continue if char is '\0'

        unless charWidths[char]?
          unless textNode?
            rangeForMeasurement ?= document.createRange()
            iterator =  document.createNodeIterator(lineNode, NodeFilter.SHOW_TEXT, AcceptFilter)
            textNode = iterator.nextNode()
            textNodeIndex = 0
            nextTextNodeIndex = textNode.textContent.length

          while nextTextNodeIndex <= charIndex
            textNode = iterator.nextNode()
            textNodeIndex = nextTextNodeIndex
            nextTextNodeIndex = textNodeIndex + textNode.textContent.length

          i = charIndex - textNodeIndex
          rangeForMeasurement.setStart(textNode, i)
          rangeForMeasurement.setEnd(textNode, i + charLength)
          charWidth = rangeForMeasurement.getBoundingClientRect().width
          editor.setScopedCharWidth(scopes, char, charWidth)
          @props.presenter.setScopedCharWidth(scopes, char, charWidth)

        charIndex += charLength

    @measuredLines.add(tokenizedLine.id)

  clearScopedCharWidths: ->
    @measuredLines.clear()
    @props.editor.clearScopedCharWidths()
    @props.presenter.clearScopedCharWidths()
