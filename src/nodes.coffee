# `nodes.coffee` contains all of the node classes for the syntax tree. Most
# nodes are created as the result of actions in the [grammar](grammar.html),
# but some are created by other nodes as a method of code generation. To convert
# the syntax tree into a string of JavaScript code, call `compile()` on the root.

Error.stackTraceLimit = Infinity

{Scope} = require './scope'
{isUnassignable, JS_FORBIDDEN} = require './lexer'

# Import the helpers we plan to use.
{compact, flatten, extend, merge, del, starts, ends, some,
addLocationDataFn, locationDataToString, throwSyntaxError} = require './helpers'

# Functions required by parser
exports.extend = extend
exports.addLocationDataFn = addLocationDataFn

# Constant functions for nodes that don't need customization.
YES     = -> yes
NO      = -> no
THIS    = -> this
NEGATE  = -> @negated = not @negated; this

#### CodeFragment

# The various nodes defined below all compile to a collection of **CodeFragment** objects.
# A CodeFragments is a block of generated code, and the location in the source file where the code
# came from. CodeFragments can be assembled together into working code just by catting together
# all the CodeFragments' `code` snippets, in order.
exports.CodeFragment = class CodeFragment
  constructor: (parent, code) ->
    @code = "#{code}"
    @locationData = parent?.locationData
    @type = parent?.constructor?.name or 'unknown'

  toString:   ->
    "#{@code}#{if @locationData then ": " + locationDataToString(@locationData) else ''}"

# Convert an array of CodeFragments into a string.
fragmentsToText = (fragments) ->
  (fragment.code for fragment in fragments).join('')

#### Base

# The **Base** is the abstract base class for all nodes in the syntax tree.
# Each subclass implements the `compileNode` method, which performs the
# code generation for that node. To compile a node to JavaScript,
# call `compile` on it, which wraps `compileNode` in some generic extra smarts,
# to know when the generated code needs to be wrapped up in a closure.
# An options hash is passed and cloned throughout, containing information about
# the environment from higher in the tree (such as if a returned value is
# being requested by the surrounding function), information about the current
# scope, and indentation level.
exports.Base = class Base

  compile: (o, lvl) ->
    fragmentsToText @compileToFragments o, lvl

  # Common logic for determining whether to wrap this node in a closure before
  # compiling it, or to compile directly. We need to wrap if this node is a
  # *statement*, and it's not a *pureStatement*, and we're not at
  # the top level of a block (which would be unnecessary), and we haven't
  # already been asked to return the result (because statements know how to
  # return results).
  compileToFragments: (o, lvl) ->
    o        = extend {}, o
    o.level  = lvl if lvl
    node     = @unfoldSoak(o) or this
    node.tab = o.indent
    if o.level is LEVEL_TOP or not node.isStatement(o)
      node.compileNode o
    else
      node.compileClosure o

  # Statements converted into expressions via closure-wrapping share a scope
  # object with their parent closure, to preserve the expected lexical scope.
  compileClosure: (o) ->
    if jumpNode = @jumps()
      jumpNode.error 'cannot use a pure statement in an expression'
    o.sharedScope = yes
    func = new Code [], Block.wrap [this]
    args = []
    if (argumentsNode = @contains isLiteralArguments) or @contains isLiteralThis
      args = [new ThisLiteral]
      if argumentsNode
        meth = 'apply'
        args.push new IdentifierLiteral 'arguments'
      else
        meth = 'call'
      func = new Value func, [new Access new PropertyName meth]
    parts = (new Call func, args).compileNode o

    switch
      when func.isGenerator or func.base?.isGenerator
        parts.unshift @makeCode "(yield* "
        parts.push    @makeCode ")"
      when func.isAsync or func.base?.isAsync
        parts.unshift @makeCode "(await "
        parts.push    @makeCode ")"
    parts

  # If the code generation wishes to use the result of a complex expression
  # in multiple places, ensure that the expression is only ever evaluated once,
  # by assigning it to a temporary variable. Pass a level to precompile.
  #
  # If `level` is passed, then returns `[val, ref]`, where `val` is the compiled value, and `ref`
  # is the compiled reference. If `level` is not passed, this returns `[val, ref]` where
  # the two values are raw nodes which have not been compiled.
  cache: (o, level, isComplex) ->
    complex = if isComplex? then isComplex this else @isComplex()
    if complex
      ref = new IdentifierLiteral o.scope.freeVariable 'ref'
      sub = new Assign ref, this
      if level then [sub.compileToFragments(o, level), [@makeCode(ref.value)]] else [sub, ref]
    else
      ref = if level then @compileToFragments o, level else this
      [ref, ref]

  # Occasionally it may be useful to make an expression behave as if it was 'hoisted', whereby the
  # result of the expression is available before its location in the source, but the expression's
  # variable scope corresponds the source position. This is used extensively to deal with executable
  # class bodies in classes.
  #
  # Calling this method mutates the node, proxying the `compileNode` and `compileToFragments`
  # methods to store their result for later replacing the `target` node, which is returned by the
  # call.
  hoist: ->
    @hoisted = yes
    target   = new HoistTarget @

    compileNode        = @compileNode
    compileToFragments = @compileToFragments

    @compileNode = (o) ->
      target.update compileNode, o

    @compileToFragments = (o) ->
      target.update compileToFragments, o

    target

  cacheToCodeFragments: (cacheValues) ->
    [fragmentsToText(cacheValues[0]), fragmentsToText(cacheValues[1])]

  # Construct a node that returns the current node's result.
  # Note that this is overridden for smarter behavior for
  # many statement nodes (e.g. If, For)...
  makeReturn: (res) ->
    me = @unwrapAll()
    if res
      new Call new Literal("#{res}.push"), [me]
    else
      new Return me

  # Does this node, or any of its children, contain a node of a certain kind?
  # Recursively traverses down the *children* nodes and returns the first one
  # that verifies `pred`. Otherwise return undefined. `contains` does not cross
  # scope boundaries.
  contains: (pred) ->
    node = undefined
    @traverseChildren no, (n) ->
      if pred n
        node = n
        return no
    node

  # Pull out the last non-comment node of a node list.
  lastNonComment: (list) ->
    i = list.length
    return list[i] while i-- when list[i] not instanceof Comment
    null

  # `toString` representation of the node, for inspecting the parse tree.
  # This is what `coffee --nodes` prints out.
  toString: (idt = '', name = @constructor.name) ->
    tree = '\n' + idt + name
    tree += '?' if @soak
    @eachChild (node) -> tree += node.toString idt + TAB
    tree

  # Passes each child to a function, breaking when the function returns `false`.
  eachChild: (func) ->
    return this unless @children
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        return this if func(child) is false
    this

  traverseChildren: (crossScope, func) ->
    @eachChild (child) ->
      recur = func(child)
      child.traverseChildren(crossScope, func) unless recur is no

  invert: ->
    new Op '!', this

  unwrapAll: ->
    node = this
    continue until node is node = node.unwrap()
    node

  # Default implementations of the common node properties and methods. Nodes
  # will override these with custom logic, if needed.
  children: []

  isStatement     : NO
  jumps           : NO
  isComplex       : YES
  isChainable     : NO
  isAssignable    : NO
  isNumber        : NO

  unwrap     : THIS
  unfoldSoak : NO

  # Is this node used to assign a certain variable?
  assigns: NO

  # For this node and all descendents, set the location data to `locationData`
  # if the location data is not already set.
  updateLocationDataIfMissing: (locationData) ->
    return this if @locationData
    @locationData = locationData

    @eachChild (child) ->
      child.updateLocationDataIfMissing locationData

  # Throw a SyntaxError associated with this node's location.
  error: (message) ->
    throwSyntaxError message, @locationData

  makeCode: (code) ->
    new CodeFragment this, code

  wrapInBraces: (fragments) ->
    [].concat @makeCode('('), fragments, @makeCode(')')

  # `fragmentsList` is an array of arrays of fragments. Each array in fragmentsList will be
  # concatonated together, with `joinStr` added in between each, to produce a final flat array
  # of fragments.
  joinFragmentArrays: (fragmentsList, joinStr) ->
    answer = []
    for fragments,i in fragmentsList
      if i then answer.push @makeCode joinStr
      answer = answer.concat fragments
    answer

#### HoistTarget

# A **HoistTargetNode** represents the output location in the node tree for a hoisted node.
# See Base#hoist.
exports.HoistTarget = class HoistTarget extends Base
  # Expands hoisted fragments in the given array
  @expand = (fragments) ->
    for fragment, i in fragments by -1 when fragment.fragments
      fragments[i..i] = fragment.fragments
    fragments

  constructor: (@source) ->
    # Holds presentational options to apply when the source node is compiled
    @options = {}

    # Placeholder fragments to be replaced by the source node's compilation
    @targetFragments = { fragments: [] }

  isStatement: (o) ->
    @source.isStatement o

  # Update the target fragments with the result of compiling the source.
  # Calls the given compile function with the node and options (overriden with the target
  # presentational options).
  update: (compile, o) ->
    @targetFragments.fragments = compile.call @source, merge o, @options

  # Copies the target indent and level, and returns the placeholder fragments
  compileToFragments: (o, level) ->
    @options.indent = o.indent
    @options.level  = level ? o.level
    [ @targetFragments ]

  compileNode: (o) ->
    @compileToFragments o

  compileClosure: (o) ->
    @compileToFragments o

#### Block

# The block is the list of expressions that forms the body of an
# indented block of code -- the implementation of a function, a clause in an
# `if`, `switch`, or `try`, and so on...
exports.Block = class Block extends Base
  constructor: (nodes) ->
    @expressions = compact flatten nodes or []

  children: ['expressions']

  # Tack an expression on to the end of this expression list.
  push: (node) ->
    @expressions.push node
    this

  # Remove and return the last expression of this expression list.
  pop: ->
    @expressions.pop()

  # Add an expression at the beginning of this expression list.
  unshift: (node) ->
    @expressions.unshift node
    this

  # If this Block consists of just a single node, unwrap it by pulling
  # it back out.
  unwrap: ->
    if @expressions.length is 1 then @expressions[0] else this

  # Is this an empty block of code?
  isEmpty: ->
    not @expressions.length

  isStatement: (o) ->
    for exp in @expressions when exp.isStatement o
      return yes
    no

  jumps: (o) ->
    for exp in @expressions
      return jumpNode if jumpNode = exp.jumps o

  # A Block node does not return its entire body, rather it
  # ensures that the final expression is returned.
  makeReturn: (res) ->
    len = @expressions.length
    while len--
      expr = @expressions[len]
      if expr not instanceof Comment
        @expressions[len] = expr.makeReturn res
        @expressions.splice(len, 1) if expr instanceof Return and not expr.expression
        break
    this

  # A **Block** is the only node that can serve as the root.
  compileToFragments: (o = {}, level) ->
    if o.scope then super o, level else @compileRoot o

  # Compile all expressions within the **Block** body. If we need to
  # return the result, and it's an expression, simply return it. If it's a
  # statement, ask the statement to do so.
  compileNode: (o) ->
    @tab  = o.indent
    top   = o.level is LEVEL_TOP
    compiledNodes = []

    for node, index in @expressions

      node = node.unwrapAll()
      node = (node.unfoldSoak(o) or node)
      if node instanceof Block
        # This is a nested block. We don't do anything special here like enclose
        # it in a new scope; we just compile the statements in this block along with
        # our own
        compiledNodes.push node.compileNode o
      else if node.hoisted
        # This is a hoisted expression. We want to compile this and ignore the result.
        node.compileToFragments o
      else if top
        node.front = true
        fragments = node.compileToFragments o
        unless node.isStatement o
          fragments.unshift @makeCode "#{@tab}"
          fragments.push @makeCode ";"
        compiledNodes.push fragments
      else
        compiledNodes.push node.compileToFragments o, LEVEL_LIST
    if top
      if @spaced
        return [].concat @joinFragmentArrays(compiledNodes, '\n\n'), @makeCode("\n")
      else
        return @joinFragmentArrays(compiledNodes, '\n')
    if compiledNodes.length
      answer = @joinFragmentArrays(compiledNodes, ', ')
    else
      answer = [@makeCode "void 0"]
    if compiledNodes.length > 1 and o.level >= LEVEL_LIST then @wrapInBraces answer else answer

  # If we happen to be the top-level **Block**, wrap everything in
  # a safety closure, unless requested not to.
  # It would be better not to generate them in the first place, but for now,
  # clean up obvious double-parentheses.
  compileRoot: (o) ->
    o.indent  = if o.bare then '' else TAB
    o.level   = LEVEL_TOP
    @spaced   = yes
    o.scope   = new Scope null, this, null, o.referencedVars ? []
    # Mark given local variables in the root scope as parameters so they don't
    # end up being declared on this block.
    o.scope.parameter name for name in o.locals or []
    prelude   = []
    unless o.bare
      preludeExps = for exp, i in @expressions
        break unless exp.unwrap() instanceof Comment
        exp
      rest = @expressions[preludeExps.length...]
      @expressions = preludeExps
      if preludeExps.length
        prelude = @compileNode merge(o, indent: '')
        prelude.push @makeCode "\n"
      @expressions = rest
    fragments = @compileWithDeclarations o
    HoistTarget.expand fragments
    return fragments if o.bare
    [].concat prelude, @makeCode("(function() {\n"), fragments, @makeCode("\n}).call(this);\n")

  # Compile the expressions body for the contents of a function, with
  # declarations of all inner variables pushed up to the top.
  compileWithDeclarations: (o) ->
    fragments = []
    post = []
    for exp, i in @expressions
      exp = exp.unwrap()
      break unless exp instanceof Comment or exp instanceof Literal
    o = merge(o, level: LEVEL_TOP)
    if i
      rest = @expressions.splice i, 9e9
      [spaced,    @spaced] = [@spaced, no]
      [fragments, @spaced] = [@compileNode(o), spaced]
      @expressions = rest
    post = @compileNode o
    {scope} = o
    if scope.expressions is this
      declars = o.scope.hasDeclarations()
      assigns = scope.hasAssignments
      if declars or assigns
        fragments.push @makeCode '\n' if i
        fragments.push @makeCode "#{@tab}var "
        if declars
          fragments.push @makeCode scope.declaredVariables().join(', ')
        if assigns
          fragments.push @makeCode ",\n#{@tab + TAB}" if declars
          fragments.push @makeCode scope.assignedVariables().join(",\n#{@tab + TAB}")
        fragments.push @makeCode ";\n#{if @spaced then '\n' else ''}"
      else if fragments.length and post.length
        fragments.push @makeCode "\n"
    fragments.concat post

  # Wrap up the given nodes as a **Block**, unless it already happens
  # to be one.
  @wrap: (nodes) ->
    return nodes[0] if nodes.length is 1 and nodes[0] instanceof Block
    new Block nodes

#### Literal

# `Literal` is a base class for static values that can be passed through
# directly into JavaScript without translation, such as: strings, numbers,
# `true`, `false`, `null`...
exports.Literal = class Literal extends Base
  constructor: (@value) ->

  isComplex: NO

  assigns: (name) ->
    name is @value

  compileNode: (o) ->
    [@makeCode @value]

  toString: ->
    " #{if @isStatement() then super else @constructor.name}: #{@value}"

exports.NumberLiteral = class NumberLiteral extends Literal

exports.InfinityLiteral = class InfinityLiteral extends NumberLiteral
  compileNode: ->
    [@makeCode '2e308']

exports.NaNLiteral = class NaNLiteral extends NumberLiteral
  constructor: ->
    super 'NaN'

  compileNode: (o) ->
    code = [@makeCode '0/0']
    if o.level >= LEVEL_OP then @wrapInBraces code else code

exports.StringLiteral = class StringLiteral extends Literal

exports.RegexLiteral = class RegexLiteral extends Literal

exports.PassthroughLiteral = class PassthroughLiteral extends Literal

exports.IdentifierLiteral = class IdentifierLiteral extends Literal
  isAssignable: YES

exports.PropertyName = class PropertyName extends Literal
  isAssignable: YES

exports.StatementLiteral = class StatementLiteral extends Literal
  isStatement: YES

  makeReturn: THIS

  jumps: (o) ->
    return this if @value is 'break' and not (o?.loop or o?.block)
    return this if @value is 'continue' and not o?.loop

  compileNode: (o) ->
    [@makeCode "#{@tab}#{@value};"]

exports.ThisLiteral = class ThisLiteral extends Literal
  constructor: ->
    super 'this'

  compileNode: (o) ->
    code = if o.scope.method?.bound then o.scope.method.context else @value
    [@makeCode code]

exports.UndefinedLiteral = class UndefinedLiteral extends Literal
  constructor: ->
    super 'undefined'

  compileNode: (o) ->
    [@makeCode if o.level >= LEVEL_ACCESS then '(void 0)' else 'void 0']

exports.NullLiteral = class NullLiteral extends Literal
  constructor: ->
    super 'null'

exports.BooleanLiteral = class BooleanLiteral extends Literal

#### Return

# A `return` is a *pureStatement* -- wrapping it in a closure wouldn't
# make sense.
exports.Return = class Return extends Base
  constructor: (@expression) ->

  children: ['expression']

  isStatement:     YES
  makeReturn:      THIS
  jumps:           THIS

  compileToFragments: (o, level) ->
    expr = @expression?.makeReturn()
    if expr and expr not instanceof Return then expr.compileToFragments o, level else super o, level

  compileNode: (o) ->
    answer = []
    # TODO: If we call expression.compile() here twice, we'll sometimes get back different results!
    answer.push @makeCode @tab + "return#{if @expression then " " else ""}"
    if @expression
      answer = answer.concat @expression.compileToFragments o, LEVEL_PAREN
    answer.push @makeCode ";"
    return answer

# `yield return` works exactly like `return`, except that it turns the function
# into a generator.
exports.YieldReturn = class YieldReturn extends Return
  compileNode: (o) ->
    unless o.scope.parent?
      @error 'yield can only occur inside functions'
    super


exports.AwaitReturn = class AwaitReturn extends Return
  compileNode: (o) ->
    unless o.scope.parent?
      @error 'await can only occur inside functions'
    super


#### Value

# A value, variable or literal or parenthesized, indexed or dotted into,
# or vanilla.
exports.Value = class Value extends Base
  constructor: (base, props, tag) ->
    return base if not props and base instanceof Value
    @base       = base
    @properties = props or []
    @[tag]      = true if tag
    return this

  children: ['base', 'properties']

  # Add a property (or *properties* ) `Access` to the list.
  add: (props) ->
    @properties = @properties.concat props
    this

  hasProperties: ->
    !!@properties.length

  bareLiteral: (type) ->
    not @properties.length and @base instanceof type

  # Some boolean checks for the benefit of other nodes.
  isArray        : -> @bareLiteral(Arr)
  isRange        : -> @bareLiteral(Range)
  isComplex      : -> @hasProperties() or @base.isComplex()
  isAssignable   : -> @hasProperties() or @base.isAssignable()
  isNumber       : -> @bareLiteral(NumberLiteral)
  isString       : -> @bareLiteral(StringLiteral)
  isRegex        : -> @bareLiteral(RegexLiteral)
  isUndefined    : -> @bareLiteral(UndefinedLiteral)
  isNull         : -> @bareLiteral(NullLiteral)
  isBoolean      : -> @bareLiteral(BooleanLiteral)
  isAtomic       : ->
    for node in @properties.concat @base
      return no if node.soak or node instanceof Call
    yes

  isNotCallable  : -> @isNumber() or @isString() or @isRegex() or
                      @isArray() or @isRange() or @isSplice() or @isObject() or
                      @isUndefined() or @isNull() or @isBoolean()

  isStatement : (o)    -> not @properties.length and @base.isStatement o
  assigns     : (name) -> not @properties.length and @base.assigns name
  jumps       : (o)    -> not @properties.length and @base.jumps o

  isObject: (onlyGenerated) ->
    return no if @properties.length
    (@base instanceof Obj) and (not onlyGenerated or @base.generated)

  isSplice: ->
    [..., lastProp] = @properties
    lastProp instanceof Slice

  looksStatic: (className) ->
    (@this or @base instanceof ThisLiteral or @base.value is className) and
      @properties.length is 1 and @properties[0].name?.value isnt 'prototype'

  # The value can be unwrapped as its inner node, if there are no attached
  # properties.
  unwrap: ->
    if @properties.length then this else @base

  # A reference has base part (`this` value) and name part.
  # We cache them separately for compiling complex expressions.
  # `a()[b()] ?= c` -> `(_base = a())[_name = b()] ? _base[_name] = c`
  cacheReference: (o) ->
    [..., name] = @properties
    if @properties.length < 2 and not @base.isComplex() and not name?.isComplex()
      return [this, this]  # `a` `a.b`
    base = new Value @base, @properties[...-1]
    if base.isComplex()  # `a().b`
      bref = new IdentifierLiteral o.scope.freeVariable 'base'
      base = new Value new Parens new Assign bref, base
    return [base, bref] unless name  # `a()`
    if name.isComplex()  # `a[b()]`
      nref = new IdentifierLiteral o.scope.freeVariable 'name'
      name = new Index new Assign nref, name.index
      nref = new Index nref
    [base.add(name), new Value(bref or base.base, [nref or name])]

  # We compile a value to JavaScript by compiling and joining each property.
  # Things get much more interesting if the chain of properties has *soak*
  # operators `?.` interspersed. Then we have to take care not to accidentally
  # evaluate anything twice when building the soak chain.
  compileNode: (o) ->
    @base.front = @front
    props = @properties
    fragments = @base.compileToFragments o, (if props.length then LEVEL_ACCESS else null)
    if props.length and SIMPLENUM.test fragmentsToText fragments
      fragments.push @makeCode '.'
    for prop in props
      fragments.push (prop.compileToFragments o)...
    fragments

  # Unfold a soak into an `If`: `a?.b` -> `a.b if a?`
  unfoldSoak: (o) ->
    @unfoldedSoak ?= do =>
      if ifn = @base.unfoldSoak o
        ifn.body.properties.push @properties...
        return ifn
      for prop, i in @properties when prop.soak
        prop.soak = off
        fst = new Value @base, @properties[...i]
        snd = new Value @base, @properties[i..]
        if fst.isComplex()
          ref = new IdentifierLiteral o.scope.freeVariable 'ref'
          fst = new Parens new Assign ref, fst
          snd.base = ref
        return new If new Existence(fst), snd, soak: on
      no

#### Comment

# CoffeeScript passes through block comments as JavaScript block comments
# at the same position.
exports.Comment = class Comment extends Base
  constructor: (@comment) ->

  isStatement:     YES
  makeReturn:      THIS

  compileNode: (o, level) ->
    comment = @comment.replace /^(\s*)#(?=\s)/gm, "$1 *"
    code = "/*#{multident comment, @tab}#{if '\n' in comment then "\n#{@tab}" else ''} */"
    code = o.indent + code if (level or o.level) is LEVEL_TOP
    [@makeCode("\n"), @makeCode(code)]

#### Call

# Node for a function invocation.
exports.Call = class Call extends Base
  constructor: (@variable, @args = [], @soak) ->
    @isNew    = false
    if @variable instanceof Value and @variable.isNotCallable()
      @variable.error "literal is not a function"

  children: ['variable', 'args']

  # Tag this invocation as creating a new instance.
  newInstance: ->
    base = @variable?.base or @variable
    if base instanceof Call and not base.isNew
      base.newInstance()
    else
      @isNew = true
    this

  # Soaked chained invocations unfold into if/else ternary structures.
  unfoldSoak: (o) ->
    if @soak
      if this instanceof SuperCall
        left = new Literal @superReference o
        rite = new Value left
      else
        return ifn if ifn = unfoldSoak o, this, 'variable'
        [left, rite] = new Value(@variable).cacheReference o
      rite = new Call rite, @args
      rite.isNew = @isNew
      left = new Literal "typeof #{ left.compile o } === \"function\""
      return new If left, new Value(rite), soak: yes
    call = this
    list = []
    loop
      if call.variable instanceof Call
        list.push call
        call = call.variable
        continue
      break unless call.variable instanceof Value
      list.push call
      break unless (call = call.variable.base) instanceof Call
    for call in list.reverse()
      if ifn
        if call.variable instanceof Call
          call.variable = ifn
        else
          call.variable.base = ifn
      ifn = unfoldSoak o, call, 'variable'
    ifn

  # Compile a vanilla function call.
  compileNode: (o) ->
    @variable?.front = @front
    compiledArgs = []
    for arg, argIndex in @args
      if argIndex then compiledArgs.push @makeCode ", "
      compiledArgs.push (arg.compileToFragments o, LEVEL_LIST)...

    fragments = []
    if this instanceof SuperCall
      preface = @superReference o
      if preface is 'super'
        preface += '('
      else
        preface += ".call(#{@superThis(o)}"
        if compiledArgs.length then preface += ", "
      fragments.push @makeCode preface
    else
      if @isNew then fragments.push @makeCode 'new '
      fragments.push @variable.compileToFragments(o, LEVEL_ACCESS)...
      fragments.push @makeCode "("
    fragments.push compiledArgs...
    fragments.push @makeCode ")"
    fragments

#### Super

# Takes care of converting `super()` calls into calls against the prototype's
# function of the same name.
exports.SuperCall = class SuperCall extends Call
  constructor: (args) ->
    super null, args ? [new Splat new IdentifierLiteral 'arguments']
    # Allow to recognize a bare `super` call without parentheses and arguments.
    @isBare = args?

  # Grab the reference to the superclass's implementation of the current
  # method.
  superReference: (o) ->
    method = o.scope.namedMethod()
    if method?.ctor
      'super'
    else if method?.klass
      {klass, name, variable} = method
      if klass.isComplex()
        bref = new IdentifierLiteral o.scope.parent.freeVariable 'base'
        base = new Value new Parens new Assign bref, klass
        variable.base = base
        variable.properties.splice 0, klass.properties.length
      if name.isComplex() or (name instanceof Index and name.index.isAssignable())
        nref = new IdentifierLiteral o.scope.parent.freeVariable 'name'
        name.index = new Assign nref, name.index
      accesses = [new Access new PropertyName '__super__']
      accesses.push new Access new PropertyName 'constructor' if method.isStatic
      accesses.push if nref? then new Index nref else name
      (new Value bref ? klass, accesses).compile o
    else
      @error 'cannot call super outside of an instance method.'

  # The appropriate `this` value for a `super` call.
  superThis : (o) ->
    method = o.scope.method
    (method and not method.klass and method.context) or "this"

#### RegexWithInterpolations

# Regexes with interpolations are in fact just a variation of a `Call` (a
# `RegExp()` call to be precise) with a `StringWithInterpolations` inside.
exports.RegexWithInterpolations = class RegexWithInterpolations extends Call
  constructor: (args = []) ->
    super (new Value new IdentifierLiteral 'RegExp'), args, false

#### TaggedTemplateCall

exports.TaggedTemplateCall = class TaggedTemplateCall extends Call
  constructor: (variable, arg, soak) ->
    arg = new StringWithInterpolations Block.wrap([ new Value arg ]) if arg instanceof StringLiteral
    super variable, [ arg ], soak

  compileNode: (o) ->
    @variable.compileToFragments(o, LEVEL_ACCESS).concat @args[0].compileToFragments(o, LEVEL_LIST)

#### Extends

# Node to extend an object's prototype with an ancestor object.
# After `goog.inherits` from the
# [Closure Library](https://github.com/google/closure-library/blob/master/closure/goog/base.js).
exports.Extends = class Extends extends Base
  constructor: (@child, @parent) ->

  children: ['child', 'parent']

  # Hooks one constructor into another's prototype chain.
  compileToFragments: (o) ->
    new Call(new Value(new Literal utility 'extend', o), [@child, @parent]).compileToFragments o

#### Access

# A `.` access into a property of a value, or the `::` shorthand for
# an access into the object's prototype.
exports.Access = class Access extends Base
  constructor: (@name, tag) ->
    @soak  = tag is 'soak'

  children: ['name']

  compileToFragments: (o) ->
    name = @name.compileToFragments o
    node = @name.unwrap()
    if node instanceof PropertyName
      if node.value in JS_FORBIDDEN
        [@makeCode('["'), name..., @makeCode('"]')]
      else
        [@makeCode('.'), name...]
    else
      [@makeCode('['), name..., @makeCode(']')]

  isComplex: NO

#### Index

# A `[ ... ]` indexed access into an array or object.
exports.Index = class Index extends Base
  constructor: (@index) ->

  children: ['index']

  compileToFragments: (o) ->
    [].concat @makeCode("["), @index.compileToFragments(o, LEVEL_PAREN), @makeCode("]")

  isComplex: ->
    @index.isComplex()

#### Range

# A range literal. Ranges can be used to extract portions (slices) of arrays,
# to specify a range for comprehensions, or as a value, to be expanded into the
# corresponding array of integers at runtime.
exports.Range = class Range extends Base

  children: ['from', 'to']

  constructor: (@from, @to, tag) ->
    @exclusive = tag is 'exclusive'
    @equals = if @exclusive then '' else '='



  # Compiles the range's source variables -- where it starts and where it ends.
  # But only if they need to be cached to avoid double evaluation.
  compileVariables: (o) ->
    o = merge o, top: true
    isComplex = del o, 'isComplex'
    [@fromC, @fromVar]  =  @cacheToCodeFragments @from.cache o, LEVEL_LIST, isComplex
    [@toC, @toVar]      =  @cacheToCodeFragments @to.cache o, LEVEL_LIST, isComplex
    [@step, @stepVar]   =  @cacheToCodeFragments step.cache o, LEVEL_LIST, isComplex if step = del o, 'step'
    @fromNum = if @from.isNumber() then Number @fromVar else null
    @toNum   = if @to.isNumber()   then Number @toVar   else null
    @stepNum = if step?.isNumber() then Number @stepVar else null

  # When compiled normally, the range returns the contents of the *for loop*
  # needed to iterate over the values in the range. Used by comprehensions.
  compileNode: (o) ->
    @compileVariables o unless @fromVar
    return @compileArray(o) unless o.index

    # Set up endpoints.
    known    = @fromNum? and @toNum?
    idx      = del o, 'index'
    idxName  = del o, 'name'
    namedIndex = idxName and idxName isnt idx
    varPart  = "#{idx} = #{@fromC}"
    varPart += ", #{@toC}" if @toC isnt @toVar
    varPart += ", #{@step}" if @step isnt @stepVar
    [lt, gt] = ["#{idx} <#{@equals}", "#{idx} >#{@equals}"]

    # Generate the condition.
    condPart = if @stepNum?
      if @stepNum > 0 then "#{lt} #{@toVar}" else "#{gt} #{@toVar}"
    else if known
      [from, to] = [@fromNum, @toNum]
      if from <= to then "#{lt} #{to}" else "#{gt} #{to}"
    else
      cond = if @stepVar then "#{@stepVar} > 0" else "#{@fromVar} <= #{@toVar}"
      "#{cond} ? #{lt} #{@toVar} : #{gt} #{@toVar}"

    # Generate the step.
    stepPart = if @stepVar
      "#{idx} += #{@stepVar}"
    else if known
      if namedIndex
        if from <= to then "++#{idx}" else "--#{idx}"
      else
        if from <= to then "#{idx}++" else "#{idx}--"
    else
      if namedIndex
        "#{cond} ? ++#{idx} : --#{idx}"
      else
        "#{cond} ? #{idx}++ : #{idx}--"

    varPart  = "#{idxName} = #{varPart}" if namedIndex
    stepPart = "#{idxName} = #{stepPart}" if namedIndex

    # The final loop body.
    [@makeCode "#{varPart}; #{condPart}; #{stepPart}"]


  # When used as a value, expand the range into the equivalent array.
  compileArray: (o) ->
    known = @fromNum? and @toNum?
    if known and Math.abs(@fromNum - @toNum) <= 20
      range = [@fromNum..@toNum]
      range.pop() if @exclusive
      return [@makeCode "[#{ range.join(', ') }]"]
    idt    = @tab + TAB
    i      = o.scope.freeVariable 'i', single: true
    result = o.scope.freeVariable 'results'
    pre    = "\n#{idt}#{result} = [];"
    if known
      o.index = i
      body    = fragmentsToText @compileNode o
    else
      vars    = "#{i} = #{@fromC}" + if @toC isnt @toVar then ", #{@toC}" else ''
      cond    = "#{@fromVar} <= #{@toVar}"
      body    = "var #{vars}; #{cond} ? #{i} <#{@equals} #{@toVar} : #{i} >#{@equals} #{@toVar}; #{cond} ? #{i}++ : #{i}--"
    post   = "{ #{result}.push(#{i}); }\n#{idt}return #{result};\n#{o.indent}"
    hasArgs = (node) -> node?.contains isLiteralArguments
    args   = ', arguments' if hasArgs(@from) or hasArgs(@to)
    [@makeCode "(function() {#{pre}\n#{idt}for (#{body})#{post}}).apply(this#{args ? ''})"]

#### Slice

# An array slice literal. Unlike JavaScript's `Array#slice`, the second parameter
# specifies the index of the end of the slice, just as the first parameter
# is the index of the beginning.
exports.Slice = class Slice extends Base

  children: ['range']

  constructor: (@range) ->

  # We have to be careful when trying to slice through the end of the array,
  # `9e9` is used because not all implementations respect `undefined` or `1/0`.
  # `9e9` should be safe because `9e9` > `2**32`, the max array length.
  compileNode: (o) ->
    {to, from} = @range
    fromCompiled = from and from.compileToFragments(o, LEVEL_PAREN) or [@makeCode '0']
    # TODO: jwalton - move this into the 'if'?
    if to
      compiled     = to.compileToFragments o, LEVEL_PAREN
      compiledText = fragmentsToText compiled
      if not (not @range.exclusive and +compiledText is -1)
        toStr = ', ' + if @range.exclusive
          compiledText
        else if to.isNumber()
          "#{+compiledText + 1}"
        else
          compiled = to.compileToFragments o, LEVEL_ACCESS
          "+#{fragmentsToText compiled} + 1 || 9e9"
    [@makeCode ".slice(#{ fragmentsToText fromCompiled }#{ toStr or '' })"]

#### Obj

# An object literal, nothing fancy.
exports.Obj = class Obj extends Base
  constructor: (props, @generated = false) ->
    @objects = @properties = props or []

  children: ['properties']

  compileNode: (o) ->
    props = @properties
    if @generated
      for node in props when node instanceof Value
        node.error 'cannot have an implicit value in an implicit object'
    idt        = o.indent += TAB
    lastNoncom = @lastNonComment @properties
    answer = []
    answer.push @makeCode "{#{if props.length is 0 then '}' else '\n'}"
    for prop, i in props
      join = if i is props.length - 1
        ''
      else if prop is lastNoncom or prop instanceof Comment
        '\n'
      else
        ',\n'
      indent = if prop instanceof Comment then '' else idt
      if prop instanceof Assign
        if prop.context isnt 'object'
          prop.operatorToken.error "unexpected #{prop.operatorToken.value}"
        if prop.variable instanceof Value and prop.variable.hasProperties()
          prop.variable.error 'invalid object key'
      if prop instanceof Value and prop.this
        prop = new Assign prop.properties[0].name, prop, 'object'
      if prop not instanceof Comment and prop not instanceof Assign
        if prop.isComplex()
          [key, value] = prop.base.cache o
          key  = new PropertyName key.value if key instanceof IdentifierLiteral
          prop = new Assign key, value, 'object'
        else
          prop = new Assign prop, prop, 'object'
      if indent then answer.push @makeCode indent
      answer.push prop.compileToFragments(o, LEVEL_TOP)...
      if join then answer.push @makeCode join
    answer.push @makeCode "\n#{@tab}}" unless props.length is 0
    if @front then @wrapInBraces answer else answer

  assigns: (name) ->
    for prop in @properties when prop.assigns name then return yes
    no

#### Arr

# An array literal.
exports.Arr = class Arr extends Base
  constructor: (objs) ->
    @objects = objs or []

  children: ['objects']

  compileNode: (o) ->
    return [@makeCode '[]'] unless @objects.length
    o.indent += TAB

    answer = []
    compiledObjs = (obj.compileToFragments o, LEVEL_LIST for obj in @objects)
    for fragments, index in compiledObjs
      if index
        answer.push @makeCode ", "
      answer.push fragments...
    if fragmentsToText(answer).indexOf('\n') >= 0
      answer.unshift @makeCode "[\n#{o.indent}"
      answer.push @makeCode "\n#{@tab}]"
    else
      answer.unshift @makeCode "["
      answer.push @makeCode "]"
    answer

  assigns: (name) ->
    for obj in @objects when obj.assigns name then return yes
    no

#### Class

# The CoffeeScript class definition.
# Initialize a **Class** with its name, an optional superclass, and a body.

exports.Class = class Class extends Base
  children: ['variable', 'parent', 'body']

  constructor: (@variable, @parent, @body = new Block) ->

  compileNode: (o) ->
    @name          = @determineName()
    executableBody = @walkBody()

    if executableBody
      @compileNode = @compileClassDeclaration
      result = new ExecutableClassBody(@, executableBody).compileToFragments o
      @compileNode = @constructor::compileNode
    else
      result = @compileClassDeclaration o

    if @variable
      assign = new Assign @variable, new Literal(''), null, { @moduleDeclaration }
      [ assign.compileToFragments(o)..., result... ]
    else
      result

  compileClassDeclaration: (o) ->
    @ctor ?= @makeDefaultConstructor() if @externalCtor or @boundMethods.length
    @ctor?.noReturn = true

    @proxyBoundMethods o
    @ensureConstructorSuperCall()

    o.indent += TAB

    result = []
    result.push @makeCode "class "
    result.push @makeCode "#{@name} " if @name
    result.push @makeCode('extends '), @parent.compileToFragments(o)..., @makeCode ' ' if @parent

    result.push @makeCode '{'
    unless @body.isEmpty()
      @body.spaced = true
      result.push @makeCode '\n'
      result.push @body.compileToFragments(o, LEVEL_TOP)...
      result.push @makeCode "\n#{@tab}"
    result.push @makeCode '}'

    result

  # Figure out the appropriate name for this class
  determineName: ->
    return null unless @variable
    [..., tail] = @variable.properties
    node = if tail
      tail instanceof Access and tail.name
    else
      @variable.base
    unless node instanceof IdentifierLiteral or node instanceof PropertyName
      return null
    name = node.value
    unless tail
      message = isUnassignable name
      @variable.error message if message
    if name in JS_FORBIDDEN then "_#{name}" else name

  walkBody: ->
    @ctor          = null
    @boundMethods  = []
    executableBody = null

    initializer     = []
    { expressions } = @body

    i = 0
    for expression in expressions.slice()
      if expression instanceof Value and expression.isObject true
        { properties } = expression.base
        exprs     = []
        end       = 0
        start     = 0
        pushSlice = -> exprs.push new Value new Obj properties[start...end], true if end > start

        while assign = properties[end]
          if initializerExpression = @addInitializerExpression assign
            pushSlice()
            exprs.push initializerExpression
            initializer.push initializerExpression
            start = end + 1
          else if initializer[initializer.length - 1] instanceof Comment
            # Try to keep comments with their subsequent assign
            exprs.pop()
            initializer.pop()
            start--
          end++
        pushSlice()

        expressions[i..i] = exprs
        i += exprs.length
      else
        if initializerExpression = @addInitializerExpression expression
          initializer.push initializerExpression
          expressions[i] = initializerExpression
        else if initializer[initializer.length - 1] instanceof Comment
          # Try to keep comments with their subsequent assign
          initializer.pop()
        i += 1

    for method in initializer when method instanceof Code
      if method.ctor
        method.error 'Cannot define more than one constructor in a class' if @ctor
        @ctor = method
      else if method.bound and method.isStatic
        method.context = @name
      else if method.bound
        @boundMethods.push method.name
        method.bound = false

    # TODO Once `super` has been changed over to ES, the check for @parent can be removed
    if @parent or initializer.length != expressions.length
      @body.expressions = (expression.hoist() for expression in initializer)
      new Block expressions

  # Add an expression to the class initializer
  #
  # NOTE Currently, only comments, methods and static methods are valid in ES class initializers.
  # When additional expressions become valid, this method should be updated to handle them.
  addInitializerExpression: (node) ->
    switch
      when node instanceof Comment
        node
      when @validInitializerMethod node
        @addInitializerMethod node
      else
        null

  # Checks if the given node is a valid ES class initializer method.
  validInitializerMethod: (node) ->
    return false unless node instanceof Assign and node.value instanceof Code
    return true if node.context is 'object' and not node.variable.hasProperties()
    return node.variable.looksStatic(@name) and (@name or not node.value.bound)

  # Returns a configured class initializer method
  addInitializerMethod: (assign) ->
    variable        = assign.variable
    method          = assign.value
    method.isMethod = yes
    method.isStatic = variable.looksStatic @name
    method.klass    = new IdentifierLiteral @name
    method.variable = variable

    if method.isStatic
      method.name = variable.properties[0]
    else
      methodName  = variable.base
      method.ctor = methodName.value is 'constructor'
      method.name = new (if methodName.isComplex() then Index else Access) methodName
      method.error 'Cannot define a constructor as a bound function' if method.bound and method.ctor

    method

  makeDefaultConstructor: ->
    ctor          = new Code
    ctor.ctor     = true
    ctor.name     = new Access new PropertyName 'constructor'
    ctor.isMethod = yes
    @body.unshift ctor

    if @externalCtor
      applyCtor = new Value @externalCtor, [ new Access new PropertyName 'apply' ]
      applyArgs = [ new ThisLiteral, new IdentifierLiteral 'arguments' ]
      ctor.body.push new Call applyCtor, applyArgs
      ctor.body.makeReturn()

    ctor

  proxyBoundMethods: (o) ->
    return unless @boundMethods.length

    for name in @boundMethods by -1
      name = new Value(new ThisLiteral, [ name ]).compile o
      @ctor.body.unshift new Literal "#{name} = #{utility 'bind', o}(#{name}, this)"

    null

  ensureConstructorSuperCall: ->
    return unless @parent and @ctor

    hasThisParam = no
    hasThisParam = yes for param in @ctor.params when param.name.this

    superCall    = @ctor.superCall()

    if hasThisParam and superCall
      superCall.error 'super not allowed with `@` parameters in derived constructors'

    if @boundMethods.length and superCall
      superCall.error 'super not allowed with bound functions in derived constructors'

    @ctor.body.unshift new SuperCall unless superCall

exports.ExecutableClassBody = class ExecutableClassBody extends Base
  children: [ 'class', 'body' ]

  defaultClassVariableName: '_Class'

  constructor: (@class, @body = new Block) ->

  compileNode: (o) ->
    if jumpNode = @body.jumps()
      jumpNode.error 'Class bodies cannot contain pure statements'
    if argumentsNode = @body.contains isLiteralArguments
      argumentsNode.error "Class bodies shouldn't reference arguments"

    @name      = @class.name ? @defaultClassVariableName
    directives = @walkBody()
    @setContext()

    ident   = new IdentifierLiteral @name
    params  = []
    args    = []
    wrapper = new Code params, @body
    klass   = new Call wrapper, args

    @body.spaced = true

    o.classScope = wrapper.makeScope o.scope

    if @externalCtor
      externalCtor = new IdentifierLiteral o.classScope.freeVariable 'ctor', reserve: no
      @class.externalCtor = externalCtor
      @externalCtor.variable.base = externalCtor

    if @class.parent
      parent = new IdentifierLiteral o.classScope.freeVariable 'superClass', reserve: no
      params.push new Param parent
      args.push @class.parent

      @class.parent = parent
      @body.unshift new Literal "#{@name}.__super__ = #{parent.value}.prototype"

    if @name != @class.name
      @body.expressions.unshift new Assign (new IdentifierLiteral @name), @class
    else
      @body.expressions.unshift @class
    @body.expressions.unshift directives...
    @body.push ident

    klass.compileToFragments o

  # Traverse the class's children and:
  # - Hoist valid ES properties into `@properties`
  # - Hoist static assignments into `@properties`
  # - Convert invalid ES properties into class or prototype assignments
  walkBody: ->
    directives  = []

    index = 0
    while expr = @body.expressions[index]
      break unless expr instanceof Comment or expr instanceof Value and expr.isString()
      if expr.hoisted
        index++
      else
        directives.push @body.expressions.splice(index, 1)...

    @traverseChildren false, (child) =>
      return false if child instanceof Class or child instanceof HoistTarget

      cont = true
      if child instanceof Block
        for node, i in child.expressions
          if node instanceof Value and node.isObject(true)
            cont = false
            child.expressions[i] = @addProperties node.base.properties
          else if node instanceof Assign and node.variable.looksStatic @name
            node.value.isStatic = yes
          else if node instanceof Code and node.isMethod
            node.klass = new IdentifierLiteral @name
        child.expressions = flatten child.expressions
      cont

    directives

  setContext: ->
    @body.traverseChildren false, (node) =>
      if node instanceof ThisLiteral
        node.value   = @name
      else if node instanceof Code and node.bound
        node.context = @name

  # Make class/prototype assignments for invalid ES properties
  addProperties: (assigns) ->
    result = for assign in assigns
      variable = assign.variable
      base     = variable?.base
      value    = assign.value
      delete assign.context

      if assign instanceof Comment
        # Passthrough
      else if base.value is 'constructor'
        if value instanceof Code
          base.error 'constructors must be defined at the top level of a class body'

        # The class scope is not available yet, so return the assignment to update later
        assign = @externalCtor = new Assign new Value, value
      else if not assign.variable.this
        name      = new (if base.isComplex() then Index else Access) base
        prototype = new Access new PropertyName 'prototype'
        variable  = new Value new ThisLiteral(), [ prototype, name ]

        assign.variable = variable
      else if assign.value instanceof Code
        assign.value.isStatic = true

      assign
    compact result

#### Import and Export

exports.ModuleDeclaration = class ModuleDeclaration extends Base
  constructor: (@clause, @source) ->
    @checkSource()

  children: ['clause', 'source']

  isStatement: YES
  jumps:       THIS
  makeReturn:  THIS

  checkSource: ->
    if @source? and @source instanceof StringWithInterpolations
      @source.error 'the name of the module to be imported from must be an uninterpolated string'

  checkScope: (o, moduleDeclarationType) ->
    if o.indent.length isnt 0
      @error "#{moduleDeclarationType} statements must be at top-level scope"

exports.ImportDeclaration = class ImportDeclaration extends ModuleDeclaration
  compileNode: (o) ->
    @checkScope o, 'import'
    o.importedSymbols = []

    code = []
    code.push @makeCode "#{@tab}import "
    code.push @clause.compileNode(o)... if @clause?

    if @source?.value?
      code.push @makeCode ' from ' unless @clause is null
      code.push @makeCode @source.value

    code.push @makeCode ';'
    code

exports.ImportClause = class ImportClause extends Base
  constructor: (@defaultBinding, @namedImports) ->

  children: ['defaultBinding', 'namedImports']

  compileNode: (o) ->
    code = []

    if @defaultBinding?
      code.push @defaultBinding.compileNode(o)...
      code.push @makeCode ', ' if @namedImports?

    if @namedImports?
      code.push @namedImports.compileNode(o)...

    code

exports.ExportDeclaration = class ExportDeclaration extends ModuleDeclaration
  compileNode: (o) ->
    @checkScope o, 'export'

    code = []
    code.push @makeCode "#{@tab}export "
    code.push @makeCode 'default ' if @ instanceof ExportDefaultDeclaration

    if @ not instanceof ExportDefaultDeclaration and
       (@clause instanceof Assign or @clause instanceof Class)
      # Prevent exporting an anonymous class; all exported members must be named
      if @clause instanceof Class and not @clause.variable
        @clause.error 'anonymous classes cannot be exported'

      code.push @makeCode 'var '
      @clause.moduleDeclaration = 'export'

    if @clause.body? and @clause.body instanceof Block
      code = code.concat @clause.compileToFragments o, LEVEL_TOP
    else
      code = code.concat @clause.compileNode o

    code.push @makeCode " from #{@source.value}" if @source?.value?
    code.push @makeCode ';'
    code

exports.ExportNamedDeclaration = class ExportNamedDeclaration extends ExportDeclaration

exports.ExportDefaultDeclaration = class ExportDefaultDeclaration extends ExportDeclaration

exports.ExportAllDeclaration = class ExportAllDeclaration extends ExportDeclaration

exports.ModuleSpecifierList = class ModuleSpecifierList extends Base
  constructor: (@specifiers) ->

  children: ['specifiers']

  compileNode: (o) ->
    code = []
    o.indent += TAB
    compiledList = (specifier.compileToFragments o, LEVEL_LIST for specifier in @specifiers)

    if @specifiers.length isnt 0
      code.push @makeCode "{\n#{o.indent}"
      for fragments, index in compiledList
        code.push @makeCode(",\n#{o.indent}") if index
        code.push fragments...
      code.push @makeCode "\n}"
    else
      code.push @makeCode '{}'
    code

exports.ImportSpecifierList = class ImportSpecifierList extends ModuleSpecifierList

exports.ExportSpecifierList = class ExportSpecifierList extends ModuleSpecifierList

exports.ModuleSpecifier = class ModuleSpecifier extends Base
  constructor: (@original, @alias, @moduleDeclarationType) ->
    # The name of the variable entering the local scope
    @identifier = if @alias? then @alias.value else @original.value

  children: ['original', 'alias']

  compileNode: (o) ->
    o.scope.add @identifier, @moduleDeclarationType
    code = []
    code.push @makeCode @original.value
    code.push @makeCode " as #{@alias.value}" if @alias?
    code

exports.ImportSpecifier = class ImportSpecifier extends ModuleSpecifier
  constructor: (imported, local) ->
    super imported, local, 'import'

  compileNode: (o) ->
    # Per the spec, symbols can’t be imported multiple times
    # (e.g. `import { foo, foo } from 'lib'` is invalid)
    if @identifier in o.importedSymbols or o.scope.check(@identifier)
      @error "'#{@identifier}' has already been declared"
    else
      o.importedSymbols.push @identifier
    super o

exports.ImportDefaultSpecifier = class ImportDefaultSpecifier extends ImportSpecifier

exports.ImportNamespaceSpecifier = class ImportNamespaceSpecifier extends ImportSpecifier

exports.ExportSpecifier = class ExportSpecifier extends ModuleSpecifier
  constructor: (local, exported) ->
    super local, exported, 'export'

#### Assign

# The **Assign** is used to assign a local variable to value, or to set the
# property of an object -- including within object literals.
exports.Assign = class Assign extends Base
  constructor: (@variable, @value, @context, options = {}) ->
    {@param, @subpattern, @operatorToken, @moduleDeclaration} = options

  children: ['variable', 'value']

  isStatement: (o) ->
    o?.level is LEVEL_TOP and @context? and (@moduleDeclaration or "?" in @context)

  checkAssignability: (o, varBase) ->
    if Object::hasOwnProperty.call(o.scope.positions, varBase.value) and
       o.scope.variables[o.scope.positions[varBase.value]].type is 'import'
      varBase.error "'#{varBase.value}' is read-only"

  assigns: (name) ->
    @[if @context is 'object' then 'value' else 'variable'].assigns name

  unfoldSoak: (o) ->
    unfoldSoak o, this, 'variable'

  # Compile an assignment, delegating to `compilePatternMatch` or
  # `compileSplice` if appropriate. Keep track of the name of the base object
  # we've been assigned to, for correct internal references. If the variable
  # has not been seen yet within the current scope, declare it.
  compileNode: (o) ->
    if isValue = @variable instanceof Value
      return @compilePatternMatch o if @variable.isArray() or @variable.isObject()
      return @compileSplice       o if @variable.isSplice()
      return @compileConditional  o if @context in ['||=', '&&=', '?=']
      return @compileSpecialMath  o if @context in ['**=', '//=', '%%=']
    if @value instanceof Code
      if @value.isStatic
        @value.klass = @variable.base
        @value.name  = @variable.properties[0]
        @value.variable = @variable
      else if @variable.properties?.length >= 2
        [properties..., prototype, name] = @variable.properties
        if prototype.name?.value is 'prototype'
          @value.klass = new Value @variable.base, properties
          @value.name  = name
          @value.variable = @variable
    unless @context
      varBase = @variable.unwrapAll()
      unless varBase.isAssignable()
        @variable.error "'#{@variable.compile o}' can't be assigned"
      unless varBase.hasProperties?()
        # `moduleDeclaration` can be `'import'` or `'export'`
        if @moduleDeclaration
          @checkAssignability o, varBase
          o.scope.add varBase.value, @moduleDeclaration
        else if @param
          o.scope.add varBase.value, 'var'
        else
          @checkAssignability o, varBase
          o.scope.find varBase.value

    val = @value.compileToFragments o, LEVEL_LIST
    @variable.front = true if isValue and @variable.base instanceof Obj
    compiledName = @variable.compileToFragments o, LEVEL_LIST

    if @context is 'object'
      if @variable.isComplex()
        compiledName.unshift @makeCode '['
        compiledName.push @makeCode ']'
      else if fragmentsToText(compiledName) in JS_FORBIDDEN
        compiledName.unshift @makeCode '"'
        compiledName.push @makeCode '"'
      return compiledName.concat @makeCode(": "), val

    answer = compiledName.concat @makeCode(" #{ @context or '=' } "), val
    if o.level <= LEVEL_LIST then answer else @wrapInBraces answer

  # Brief implementation of recursive pattern matching, when assigning array or
  # object literals to a value. Peeks at their properties to assign inner names.
  compilePatternMatch: (o) ->
    top       = o.level is LEVEL_TOP
    {value}   = this
    {objects} = @variable.base
    unless olen = objects.length
      code = value.compileToFragments o
      return if o.level >= LEVEL_OP then @wrapInBraces code else code
    [obj] = objects
    if olen is 1 and obj instanceof Expansion
      obj.error 'Destructuring assignment has no target'
    isObject = @variable.isObject()
    if top and olen is 1 and obj not instanceof Splat
      # Pick the property straight off the value when there’s just one to pick
      # (no need to cache the value into a variable).
      defaultValue = null
      if obj instanceof Assign and obj.context is 'object'
        # A regular object pattern-match.
        {variable: {base: idx}, value: obj} = obj
        if obj instanceof Assign
          defaultValue = obj.value
          obj = obj.variable
      else
        if obj instanceof Assign
          defaultValue = obj.value
          obj = obj.variable
        idx = if isObject
          # A shorthand `{a, b, @c} = val` pattern-match.
          if obj.this
            obj.properties[0].name
          else
            new PropertyName obj.unwrap().value
        else
          # A regular array pattern-match.
          new NumberLiteral 0
      acc   = idx.unwrap() instanceof PropertyName
      value = new Value value
      value.properties.push new (if acc then Access else Index) idx
      message = isUnassignable obj.unwrap().value
      obj.error message if message
      value = new Op '?', value, defaultValue if defaultValue
      return new Assign(obj, value, null, param: @param).compileToFragments o, LEVEL_TOP
    vvar     = value.compileToFragments o, LEVEL_LIST
    vvarText = fragmentsToText vvar
    assigns  = []
    expandedIdx = false
    # Make vvar into a simple variable if it isn't already.
    if value.unwrap() not instanceof IdentifierLiteral or @variable.assigns(vvarText)
      assigns.push [@makeCode("#{ ref = o.scope.freeVariable 'ref' } = "), vvar...]
      vvar = [@makeCode ref]
      vvarText = ref
    for obj, i in objects
      idx = i
      if not expandedIdx and obj instanceof Splat
        name = obj.name.unwrap().value
        obj = obj.unwrap()
        val = "#{olen} <= #{vvarText}.length ? #{ utility 'slice', o }.call(#{vvarText}, #{i}"
        if rest = olen - i - 1
          ivar = o.scope.freeVariable 'i', single: true
          val += ", #{ivar} = #{vvarText}.length - #{rest}) : (#{ivar} = #{i}, [])"
        else
          val += ") : []"
        val   = new Literal val
        expandedIdx = "#{ivar}++"
      else if not expandedIdx and obj instanceof Expansion
        if rest = olen - i - 1
          if rest is 1
            expandedIdx = "#{vvarText}.length - 1"
          else
            ivar = o.scope.freeVariable 'i', single: true
            val = new Literal "#{ivar} = #{vvarText}.length - #{rest}"
            expandedIdx = "#{ivar}++"
            assigns.push val.compileToFragments o, LEVEL_LIST
        continue
      else
        if obj instanceof Splat or obj instanceof Expansion
          obj.error "multiple splats/expansions are disallowed in an assignment"
        defaultValue = null
        if obj instanceof Assign and obj.context is 'object'
          # A regular object pattern-match.
          {variable: {base: idx}, value: obj} = obj
          if obj instanceof Assign
            defaultValue = obj.value
            obj = obj.variable
        else
          if obj instanceof Assign
            defaultValue = obj.value
            obj = obj.variable
          idx = if isObject
            # A shorthand `{a, b, @c} = val` pattern-match.
            if obj.this
              obj.properties[0].name
            else
              new PropertyName obj.unwrap().value
          else
            # A regular array pattern-match.
            new Literal expandedIdx or idx
        name = obj.unwrap().value
        acc = idx.unwrap() instanceof PropertyName
        val = new Value new Literal(vvarText), [new (if acc then Access else Index) idx]
        val = new Op '?', val, defaultValue if defaultValue
      if name?
        message = isUnassignable name
        obj.error message if message
      assigns.push new Assign(obj, val, null, param: @param, subpattern: yes).compileToFragments o, LEVEL_LIST
    assigns.push vvar unless top or @subpattern
    fragments = @joinFragmentArrays assigns, ', '
    if o.level < LEVEL_LIST then fragments else @wrapInBraces fragments

  # When compiling a conditional assignment, take care to ensure that the
  # operands are only evaluated once, even though we have to reference them
  # more than once.
  compileConditional: (o) ->
    [left, right] = @variable.cacheReference o
    # Disallow conditional assignment of undefined variables.
    if not left.properties.length and left.base instanceof Literal and
           left.base not instanceof ThisLiteral and not o.scope.check left.base.value
      @variable.error "the variable \"#{left.base.value}\" can't be assigned with #{@context} because it has not been declared before"
    if "?" in @context
      o.isExistentialEquals = true
      new If(new Existence(left), right, type: 'if').addElse(new Assign(right, @value, '=')).compileToFragments o
    else
      fragments = new Op(@context[...-1], left, new Assign(right, @value, '=')).compileToFragments o
      if o.level <= LEVEL_LIST then fragments else @wrapInBraces fragments

  # Convert special math assignment operators like `a **= b` to the equivalent
  # extended form `a = a ** b` and then compiles that.
  compileSpecialMath: (o) ->
    [left, right] = @variable.cacheReference o
    new Assign(left, new Op(@context[...-1], right, @value)).compileToFragments o

  # Compile the assignment from an array splice literal, using JavaScript's
  # `Array#splice` method.
  compileSplice: (o) ->
    {range: {from, to, exclusive}} = @variable.properties.pop()
    name = @variable.compile o
    if from
      [fromDecl, fromRef] = @cacheToCodeFragments from.cache o, LEVEL_OP
    else
      fromDecl = fromRef = '0'
    if to
      if from?.isNumber() and to.isNumber()
        to = to.compile(o) - fromRef
        to += 1 unless exclusive
      else
        to = to.compile(o, LEVEL_ACCESS) + ' - ' + fromRef
        to += ' + 1' unless exclusive
    else
      to = "9e9"
    [valDef, valRef] = @value.cache o, LEVEL_LIST
    answer = [].concat @makeCode("[].splice.apply(#{name}, [#{fromDecl}, #{to}].concat("), valDef, @makeCode(")), "), valRef
    if o.level > LEVEL_TOP then @wrapInBraces answer else answer

#### Code

# A function definition. This is the only node that creates a new Scope.
# When for the purposes of walking the contents of a function body, the Code
# has no *children* -- they're within the inner scope.
exports.Code = class Code extends Base
  constructor: (params, body, tag) ->
    @params      = params or []
    @body        = body or new Block
    @bound       = tag is 'boundfunc'
    @isGenerator = no
    @isAsync     = no
    @isMethod    = no

    @body.traverseChildren no, (node) =>
      if (node instanceof Op and node.isYield()) or node instanceof YieldReturn
        @isGenerator = yes
      if (node instanceof Op and node.isAwait()) or node instanceof AwaitReturn
        @isAsync = yes
      if @isGenerator and @isAsync
        node.error "function can't contain both yield and await"

  children: ['params', 'body']

  isStatement: -> @isMethod

  jumps: NO

  makeScope: (parentScope) -> new Scope parentScope, @body, this

  # Compilation creates a new scope unless explicitly asked to share with the
  # outer scope. Handles splat parameters in the parameter list by setting
  # such parameters to be the final parameter in the function definition, as
  # required per the ES2015 spec. If the CoffeeScript function definition had
  # parameters after the splat, they are declared via expressions in the
  # function body.
  compileNode: (o) ->
    if @bound
      @context = o.scope.method.context if o.scope.method?.bound
      @context = 'this' unless @context

    o.scope         = del(o, 'classScope') or @makeScope o.scope
    o.scope.shared  = del(o, 'sharedScope')
    o.indent        += TAB
    delete o.bare
    delete o.isExistentialEquals
    params           = []
    exprs            = []
    paramsAfterSplat = []
    haveSplatParam   = no
    haveThisParam    = no

    # Check for duplicate parameters.
    paramNames = []
    @eachParamName (name, node) =>
      node.error "multiple parameters named '#{name}'" if name in paramNames
      paramNames.push name
      haveThisParam = yes if node.this

    if @ctor
      @variable.error 'Class constructor may not be async' if @isAsync
      @variable.error 'Class constructor may not be a generator' if @isGenerator

      # If there's a super call as the first expression in a constructor, it needs to stay above any
      # `this` assignments
      if haveThisParam and @body.expressions[0] instanceof SuperCall
        exprs.push @body.expressions.shift()

    # Parse the parameters, adding them to the list of parameters to put in the
    # function definition; and dealing with splats or expansions, including
    # adding expressions to the function body to declare all parameter
    # variables that would have been after the splat/expansion parameter.
    for param, i in @params
      # Was `...` used with this parameter? (Only one such parameter is allowed
      # per function.) Splat/expansion parameters cannot have default values,
      # so we need not worry about that.
      if param.splat or param instanceof Expansion
        if haveSplatParam
          param.error 'only one splat or expansion parameter is allowed per function definition'
        else if param instanceof Expansion and @params.length is 1
          param.error 'an expansion parameter cannot be the only parameter in a function definition'

        haveSplatParam = yes
        if param.splat
          params.push ref = param.asReference o
          splatParamName = fragmentsToText ref.compileNode o
          if param.isComplex() # Parameter is destructured or attached to `this`
            exprs.push new Assign new Value(param.name), ref, '=', param: yes
            # TODO: output destrucutred parameters as is, *unless* they contain
            # `this` parameters; and fix destructuring of objects with default
            # values to work in this context (see Obj.compileNode
            # `if prop.context isnt 'object'`)

        else # `param` is an Expansion
          splatParamName = o.scope.freeVariable 'args'
          params.push new Value new IdentifierLiteral splatParamName

        o.scope.parameter splatParamName

      # Parse all other parameters; if a splat paramater has not yet been
      # encountered, add these other parameters to the list to be output in
      # the function definition.
      else
        if param.isComplex()
          # This parameter is attached to `this`, which ES doesn’t allow;
          # or it’s destructured. So add a statement to the function body
          # assigning it, e.g. `(a) => { this.a = a; }` or with a default
          # value if it has one.
          val = ref = param.asReference o
          val = new Op '?', ref, param.value if param.value
          exprs.push new Assign new Value(param.name), val, '=', param: yes

        # If this parameter comes before the splat or expansion, it will go
        # in the function definition parameter list.
        unless haveSplatParam
          # If this parameter has a default value, and it hasn’t already been
          # set by the `isComplex()` block above, define it as a statement in
          # the function body. This parameter comes after the splat parameter,
          # so we can’t define its default value in the parameter list.
          unless param.isComplex()
            ref = if param.value? then new Assign new Value(param.name), param.value, '=' else param
          # Add this parameter’s reference to the function scope
          o.scope.parameter fragmentsToText (if param.value? then param else ref).compileToFragments o
          params.push ref
        else
          paramsAfterSplat.push param
          # If this parameter had a default value, since it’s no longer in the
          # function parameter list we need to assign its default value
          # (if necessary) as an expression in the body.
          if param.value? and not param.isComplex()
            condition = new Literal param.name.value + ' === undefined'
            ifTrue = new Assign new Value(param.name), param.value, '='
            exprs.push new If condition, ifTrue
          # Add this parameter to the scope, since it wouldn’t have been added yet since it was skipped earlier.
          o.scope.add param.name.value, 'var', yes if param.name?.value?

    # If there were parameters after the splat or expansion parameter, those
    # parameters need to be assigned in the body of the function.
    if paramsAfterSplat.length isnt 0
      # Create a destructured assignment, e.g. `[a, b, c] = [args..., b, c]`
      exprs.unshift new Assign new Value(
          new Arr [new Splat(new IdentifierLiteral(splatParamName)), (param.asReference o for param in paramsAfterSplat)...]
        ), new Value new IdentifierLiteral splatParamName

    # Add new expressions to the function body
    wasEmpty = @body.isEmpty()
    @body.expressions.unshift exprs... if exprs.length
    @body.makeReturn() unless wasEmpty or @noReturn

    # Assemble the output
    modifiers = []
    modifiers.push 'static'   if @isMethod and @isStatic
    modifiers.push 'async'    if @isAsync
    modifiers.push 'function' if not @isMethod and not @bound
    modifiers.push '*'        if @isGenerator

    signature = [@makeCode '(']
    for param, i in params
      signature.push @makeCode ', ' if i
      signature.push @makeCode '...' if haveSplatParam and i is params.length - 1
      signature.push param.compileToFragments(o)...
    signature.push @makeCode ')'

    body = @body.compileWithDeclarations o unless @body.isEmpty()

    # We need to compile the body before method names to ensure super references are handled
    if @isMethod
      name = @name.compileToFragments o
      name.shift() if name[0].code is '.'

    answer = @joinFragmentArrays (@makeCode m for m in modifiers), ' '
    answer.push @makeCode ' ' if modifiers.length and name
    answer.push name... if name
    answer.push signature...
    answer.push @makeCode ' =>' if @bound and not @isMethod
    answer.push @makeCode ' {'
    answer.push @makeCode('\n'), body..., @makeCode("\n#{@tab}") if body?.length
    answer.push @makeCode '}'

    return [@makeCode(@tab), answer...] if @isMethod
    if @front or (o.level >= LEVEL_ACCESS) then @wrapInBraces answer else answer

  eachParamName: (iterator) ->
    param.eachName iterator for param in @params

  # Short-circuit `traverseChildren` method to prevent it from crossing scope
  # boundaries unless `crossScope` is `true`.
  traverseChildren: (crossScope, func) ->
    super(crossScope, func) if crossScope

  # Find a super call in this function
  superCall: ->
    superCall = null
    @traverseChildren true, (child) ->
      superCall = child if child instanceof SuperCall

      # `super` has the same target in bound (arrow) functions, so check them too
      not superCall and (child not instanceof Code or child.bound)
    superCall

#### Param

# A parameter in a function definition. Beyond a typical JavaScript parameter,
# these parameters can also attach themselves to the context of the function,
# as well as be a splat, gathering up a group of parameters into an array.
exports.Param = class Param extends Base
  constructor: (@name, @value, @splat) ->
    message = isUnassignable @name.unwrapAll().value
    @name.error message if message
    if @name instanceof Obj and @name.generated
      token = @name.objects[0].operatorToken
      token.error "unexpected #{token.value}"

  children: ['name', 'value']

  compileToFragments: (o) ->
    @name.compileToFragments o, LEVEL_LIST

  asReference: (o) ->
    return @reference if @reference
    node = @name
    if node.this
      name = node.properties[0].name.value
      name = "_#{name}" if name in JS_FORBIDDEN
      node = new IdentifierLiteral o.scope.freeVariable name
    else if node.isComplex()
      node = new IdentifierLiteral o.scope.freeVariable 'arg'
    node = new Value node
    node.updateLocationDataIfMissing @locationData
    @reference = node

  isComplex: ->
    @name.isComplex()

  # Iterates the name or names of a `Param`.
  # In a sense, a destructured parameter represents multiple JS parameters. This
  # method allows to iterate them all.
  # The `iterator` function will be called as `iterator(name, node)` where
  # `name` is the name of the parameter and `node` is the AST node corresponding
  # to that name.
  eachName: (iterator, name = @name) ->
    atParam = (obj) -> iterator "@#{obj.properties[0].name.value}", obj
    # * simple literals `foo`
    return iterator name.value, name if name instanceof Literal
    # * at-params `@foo`
    return atParam name if name instanceof Value
    for obj in name.objects ? []
      # * destructured parameter with default value
      if obj instanceof Assign and not obj.context?
        obj = obj.variable
      # * assignments within destructured parameters `{foo:bar}`
      if obj instanceof Assign
        # ... possibly with a default value
        if obj.value instanceof Assign
          obj = obj.value
        @eachName iterator, obj.value.unwrap()
      # * splats within destructured parameters `[xs...]`
      else if obj instanceof Splat
        node = obj.name.unwrap()
        iterator node.value, node
      else if obj instanceof Value
        # * destructured parameters within destructured parameters `[{a}]`
        if obj.isArray() or obj.isObject()
          @eachName iterator, obj.base
        # * at-params within destructured parameters `{@foo}`
        else if obj.this
          atParam obj
        # * simple destructured parameters {foo}
        else iterator obj.base.value, obj.base
      else if obj not instanceof Expansion
        obj.error "illegal parameter #{obj.compile()}"
    return

#### Splat

# A splat, either as a parameter to a function, an argument to a call,
# or as part of a destructuring assignment.
exports.Splat = class Splat extends Base

  children: ['name']

  isAssignable: YES

  constructor: (name) ->
    @name = if name.compile then name else new Literal name

  assigns: (name) ->
    @name.assigns name

  compileToFragments: (o) ->
    [ @makeCode('...')
      @name.compileToFragments(o)... ]

  unwrap: -> @name

#### Expansion

# Used to skip values inside an array destructuring (pattern matching) or
# parameter list.
exports.Expansion = class Expansion extends Base

  isComplex: NO

  compileNode: (o) ->
    @error 'Expansion must be used inside a destructuring assignment or parameter list'

  asReference: (o) ->
    this

  eachName: (iterator) ->

#### While

# A while loop, the only sort of low-level loop exposed by CoffeeScript. From
# it, all other loops can be manufactured. Useful in cases where you need more
# flexibility or more speed than a comprehension can provide.
exports.While = class While extends Base
  constructor: (condition, options) ->
    @condition = if options?.invert then condition.invert() else condition
    @guard     = options?.guard

  children: ['condition', 'guard', 'body']

  isStatement: YES

  makeReturn: (res) ->
    if res
      super
    else
      @returns = not @jumps loop: yes
      this

  addBody: (@body) ->
    this

  jumps: ->
    {expressions} = @body
    return no unless expressions.length
    for node in expressions
      return jumpNode if jumpNode = node.jumps loop: yes
    no

  # The main difference from a JavaScript *while* is that the CoffeeScript
  # *while* can be used as a part of a larger expression -- while loops may
  # return an array containing the computed result of each iteration.
  compileNode: (o) ->
    o.indent += TAB
    set      = ''
    {body}   = this
    if body.isEmpty()
      body = @makeCode ''
    else
      if @returns
        body.makeReturn rvar = o.scope.freeVariable 'results'
        set  = "#{@tab}#{rvar} = [];\n"
      if @guard
        if body.expressions.length > 1
          body.expressions.unshift new If (new Parens @guard).invert(), new StatementLiteral "continue"
        else
          body = Block.wrap [new If @guard, body] if @guard
      body = [].concat @makeCode("\n"), (body.compileToFragments o, LEVEL_TOP), @makeCode("\n#{@tab}")
    answer = [].concat @makeCode(set + @tab + "while ("), @condition.compileToFragments(o, LEVEL_PAREN),
      @makeCode(") {"), body, @makeCode("}")
    if @returns
      answer.push @makeCode "\n#{@tab}return #{rvar};"
    answer

#### Op

# Simple Arithmetic and logical operations. Performs some conversion from
# CoffeeScript operations into their JavaScript equivalents.
exports.Op = class Op extends Base
  constructor: (op, first, second, flip ) ->
    return new In first, second if op is 'in'
    if op is 'do'
      return @generateDo first
    if op is 'new'
      return first.newInstance() if first instanceof Call and not first.do and not first.isNew
      first = new Parens first   if first instanceof Code and first.bound or first.do
    @operator = CONVERSIONS[op] or op
    @first    = first
    @second   = second
    @flip     = !!flip
    return this

  # The map of conversions from CoffeeScript to JavaScript symbols.
  CONVERSIONS =
    '==':        '==='
    '!=':        '!=='
    'of':        'in'
    'yieldfrom': 'yield*'

  # The map of invertible operators.
  INVERSIONS =
    '!==': '==='
    '===': '!=='

  children: ['first', 'second']

  isNumber: ->
    @isUnary() and @operator in ['+', '-'] and
      @first instanceof Value and @first.isNumber()

  isAwait: ->
    @operator is 'await'

  isYield: ->
    @operator in ['yield', 'yield*']

  isUnary: ->
    not @second

  isComplex: ->
    not @isNumber()

  # Am I capable of
  # [Python-style comparison chaining](http://docs.python.org/reference/expressions.html#notin)?
  isChainable: ->
    @operator in ['<', '>', '>=', '<=', '===', '!==']

  invert: ->
    if @isChainable() and @first.isChainable()
      allInvertable = yes
      curr = this
      while curr and curr.operator
        allInvertable and= (curr.operator of INVERSIONS)
        curr = curr.first
      return new Parens(this).invert() unless allInvertable
      curr = this
      while curr and curr.operator
        curr.invert = !curr.invert
        curr.operator = INVERSIONS[curr.operator]
        curr = curr.first
      this
    else if op = INVERSIONS[@operator]
      @operator = op
      if @first.unwrap() instanceof Op
        @first.invert()
      this
    else if @second
      new Parens(this).invert()
    else if @operator is '!' and (fst = @first.unwrap()) instanceof Op and
                                  fst.operator in ['!', 'in', 'instanceof']
      fst
    else
      new Op '!', this

  unfoldSoak: (o) ->
    @operator in ['++', '--', 'delete'] and unfoldSoak o, this, 'first'

  generateDo: (exp) ->
    passedParams = []
    func = if exp instanceof Assign and (ref = exp.value.unwrap()) instanceof Code
      ref
    else
      exp
    for param in func.params or []
      if param.value
        passedParams.push param.value
        delete param.value
      else
        passedParams.push param
    call = new Call exp, passedParams
    call.do = yes
    call

  compileNode: (o) ->
    isChain = @isChainable() and @first.isChainable()
    # In chains, there's no need to wrap bare obj literals in parens,
    # as the chained expression is wrapped.
    @first.front = @front unless isChain
    if @operator is 'delete' and o.scope.check(@first.unwrapAll().value)
      @error 'delete operand may not be argument or var'
    if @operator in ['--', '++']
      message = isUnassignable @first.unwrapAll().value
      @first.error message if message
    return @compileContinuation o if @isYield() or @isAwait()
    return @compileUnary        o if @isUnary()
    return @compileChain        o if isChain
    switch @operator
      when '?'  then @compileExistence o
      when '**' then @compilePower o
      when '//' then @compileFloorDivision o
      when '%%' then @compileModulo o
      else
        lhs = @first.compileToFragments o, LEVEL_OP
        rhs = @second.compileToFragments o, LEVEL_OP
        answer = [].concat lhs, @makeCode(" #{@operator} "), rhs
        if o.level <= LEVEL_OP then answer else @wrapInBraces answer

  # Mimic Python's chained comparisons when multiple comparison operators are
  # used sequentially. For example:
  #
  #     bin/coffee -e 'console.log 50 < 65 > 10'
  #     true
  compileChain: (o) ->
    [@first.second, shared] = @first.second.cache o
    fst = @first.compileToFragments o, LEVEL_OP
    fragments = fst.concat @makeCode(" #{if @invert then '&&' else '||'} "),
      (shared.compileToFragments o), @makeCode(" #{@operator} "), (@second.compileToFragments o, LEVEL_OP)
    @wrapInBraces fragments

  # Keep reference to the left expression, unless this an existential assignment
  compileExistence: (o) ->
    if @first.isComplex()
      ref = new IdentifierLiteral o.scope.freeVariable 'ref'
      fst = new Parens new Assign ref, @first
    else
      fst = @first
      ref = fst
    new If(new Existence(fst), ref, type: 'if').addElse(@second).compileToFragments o

  # Compile a unary **Op**.
  compileUnary: (o) ->
    parts = []
    op = @operator
    parts.push [@makeCode op]
    if op is '!' and @first instanceof Existence
      @first.negated = not @first.negated
      return @first.compileToFragments o
    if o.level >= LEVEL_ACCESS
      return (new Parens this).compileToFragments o
    plusMinus = op in ['+', '-']
    parts.push [@makeCode(' ')] if op in ['new', 'typeof', 'delete'] or
                      plusMinus and @first instanceof Op and @first.operator is op
    if (plusMinus and @first instanceof Op) or (op is 'new' and @first.isStatement o)
      @first = new Parens @first
    parts.push @first.compileToFragments o, LEVEL_OP
    parts.reverse() if @flip
    @joinFragmentArrays parts, ''

  compileContinuation: (o) ->
    parts = []
    op = @operator
    unless o.scope.parent?
      @error "#{@operator} can only occur inside functions"
    if o.scope.method?.bound and o.scope.method.isGenerator
      @error 'yield cannot occur inside bound (fat arrow) functions'
    if 'expression' in Object.keys(@first) and not (@first instanceof Throw)
      parts.push @first.expression.compileToFragments o, LEVEL_OP if @first.expression?
    else
      parts.push [@makeCode "("] if o.level >= LEVEL_PAREN
      parts.push [@makeCode op]
      parts.push [@makeCode " "] if @first.base?.value isnt ''
      parts.push @first.compileToFragments o, LEVEL_OP
      parts.push [@makeCode ")"] if o.level >= LEVEL_PAREN
    @joinFragmentArrays parts, ''

  compilePower: (o) ->
    # Make a Math.pow call
    pow = new Value new IdentifierLiteral('Math'), [new Access new PropertyName 'pow']
    new Call(pow, [@first, @second]).compileToFragments o

  compileFloorDivision: (o) ->
    floor = new Value new IdentifierLiteral('Math'), [new Access new PropertyName 'floor']
    div = new Op '/', @first, @second
    new Call(floor, [div]).compileToFragments o

  compileModulo: (o) ->
    mod = new Value new Literal utility 'modulo', o
    new Call(mod, [@first, @second]).compileToFragments o

  toString: (idt) ->
    super idt, @constructor.name + ' ' + @operator

#### In
exports.In = class In extends Base
  constructor: (@object, @array) ->

  children: ['object', 'array']

  invert: NEGATE

  compileNode: (o) ->
    if @array instanceof Value and @array.isArray() and @array.base.objects.length
      for obj in @array.base.objects when obj instanceof Splat
        hasSplat = yes
        break
      # `compileOrTest` only if we have an array literal with no splats
      return @compileOrTest o unless hasSplat
    @compileLoopTest o

  compileOrTest: (o) ->
    [sub, ref] = @object.cache o, LEVEL_OP
    [cmp, cnj] = if @negated then [' !== ', ' && '] else [' === ', ' || ']
    tests = []
    for item, i in @array.base.objects
      if i then tests.push @makeCode cnj
      tests = tests.concat (if i then ref else sub), @makeCode(cmp), item.compileToFragments(o, LEVEL_ACCESS)
    if o.level < LEVEL_OP then tests else @wrapInBraces tests

  compileLoopTest: (o) ->
    [sub, ref] = @object.cache o, LEVEL_LIST
    fragments = [].concat @makeCode(utility('indexOf', o) + ".call("), @array.compileToFragments(o, LEVEL_LIST),
      @makeCode(", "), ref, @makeCode(") " + if @negated then '< 0' else '>= 0')
    return fragments if fragmentsToText(sub) is fragmentsToText(ref)
    fragments = sub.concat @makeCode(', '), fragments
    if o.level < LEVEL_LIST then fragments else @wrapInBraces fragments

  toString: (idt) ->
    super idt, @constructor.name + if @negated then '!' else ''

#### Try

# A classic *try/catch/finally* block.
exports.Try = class Try extends Base
  constructor: (@attempt, @errorVariable, @recovery, @ensure) ->

  children: ['attempt', 'recovery', 'ensure']

  isStatement: YES

  jumps: (o) -> @attempt.jumps(o) or @recovery?.jumps(o)

  makeReturn: (res) ->
    @attempt  = @attempt .makeReturn res if @attempt
    @recovery = @recovery.makeReturn res if @recovery
    this

  # Compilation is more or less as you would expect -- the *finally* clause
  # is optional, the *catch* is not.
  compileNode: (o) ->
    o.indent  += TAB
    tryPart   = @attempt.compileToFragments o, LEVEL_TOP

    catchPart = if @recovery
      generatedErrorVariableName = o.scope.freeVariable 'error', reserve: no
      placeholder = new IdentifierLiteral generatedErrorVariableName
      if @errorVariable
        message = isUnassignable @errorVariable.unwrapAll().value
        @errorVariable.error message if message
        @recovery.unshift new Assign @errorVariable, placeholder
      [].concat @makeCode(" catch ("), placeholder.compileToFragments(o), @makeCode(") {\n"),
        @recovery.compileToFragments(o, LEVEL_TOP), @makeCode("\n#{@tab}}")
    else unless @ensure or @recovery
      generatedErrorVariableName = o.scope.freeVariable 'error', reserve: no
      [@makeCode(" catch (#{generatedErrorVariableName}) {}")]
    else
      []

    ensurePart = if @ensure then ([].concat @makeCode(" finally {\n"), @ensure.compileToFragments(o, LEVEL_TOP),
      @makeCode("\n#{@tab}}")) else []

    [].concat @makeCode("#{@tab}try {\n"),
      tryPart,
      @makeCode("\n#{@tab}}"), catchPart, ensurePart

#### Throw

# Simple node to throw an exception.
exports.Throw = class Throw extends Base
  constructor: (@expression) ->

  children: ['expression']

  isStatement: YES
  jumps:       NO

  # A **Throw** is already a return, of sorts...
  makeReturn: THIS

  compileNode: (o) ->
    [].concat @makeCode(@tab + "throw "), @expression.compileToFragments(o), @makeCode(";")

#### Existence

# Checks a variable for existence -- not *null* and not *undefined*. This is
# similar to `.nil?` in Ruby, and avoids having to consult a JavaScript truth
# table.
exports.Existence = class Existence extends Base
  constructor: (@expression) ->

  children: ['expression']

  invert: NEGATE

  compileNode: (o) ->
    @expression.front = @front
    code = @expression.compile o, LEVEL_OP
    if @expression.unwrap() instanceof IdentifierLiteral and not o.scope.check code
      [cmp, cnj] = if @negated then ['===', '||'] else ['!==', '&&']
      code = "typeof #{code} #{cmp} \"undefined\" #{cnj} #{code} #{cmp} null"
    else
      # do not use strict equality here; it will break existing code
      code = "#{code} #{if @negated then '==' else '!='} null"
    [@makeCode(if o.level <= LEVEL_COND then code else "(#{code})")]

#### Parens

# An extra set of parentheses, specified explicitly in the source. At one time
# we tried to clean up the results by detecting and removing redundant
# parentheses, but no longer -- you can put in as many as you please.
#
# Parentheses are a good way to force any statement to become an expression.
exports.Parens = class Parens extends Base
  constructor: (@body) ->

  children: ['body']

  unwrap    : -> @body
  isComplex : -> @body.isComplex()

  compileNode: (o) ->
    expr = @body.unwrap()
    if expr instanceof Value and expr.isAtomic()
      expr.front = @front
      return expr.compileToFragments o
    fragments = expr.compileToFragments o, LEVEL_PAREN
    bare = o.level < LEVEL_OP and (expr instanceof Op or expr instanceof Call or
      (expr instanceof For and expr.returns))
    if bare then fragments else @wrapInBraces fragments

#### StringWithInterpolations

exports.StringWithInterpolations = class StringWithInterpolations extends Base
  constructor: (@body) ->

  children: ['body']

  # `unwrap` returns `this` to stop ancestor nodes reaching in to grab @body,
  # and using @body.compileNode. `StringWithInterpolations.compileNode` is
  # _the_ custom logic to output interpolated strings as code.
  unwrap: -> this

  isComplex : -> @body.isComplex()

  compileNode: (o) ->
    # Assumes that `expr` is `Value` » `StringLiteral` or `Op`
    expr = @body.unwrap()

    elements = []
    expr.traverseChildren no, (node) ->
      if node instanceof StringLiteral
        elements.push node
        return yes
      else if node instanceof Parens
        elements.push node
        return no
      return yes

    fragments = []
    fragments.push @makeCode '`'
    for element in elements
      if element instanceof StringLiteral
        value = element.value[1...-1]
        # Backticks and `${` inside template literals must be escaped.
        value = value.replace /(\\*)(`|\$\{)/g, (match, backslashes, toBeEscaped) ->
          if backslashes.length % 2 is 0
            "#{backslashes}\\#{toBeEscaped}"
          else
            match
        fragments.push @makeCode value
      else
        fragments.push @makeCode '${'
        fragments.push element.compileToFragments(o, LEVEL_PAREN)...
        fragments.push @makeCode '}'
    fragments.push @makeCode '`'

    fragments

#### For

# CoffeeScript's replacement for the *for* loop is our array and object
# comprehensions, that compile into *for* loops here. They also act as an
# expression, able to return the result of each filtered iteration.
#
# Unlike Python array comprehensions, they can be multi-line, and you can pass
# the current index of the loop as a second parameter. Unlike Ruby blocks,
# you can map and filter in a single pass.
exports.For = class For extends While
  constructor: (body, source) ->
    {@source, @guard, @step, @name, @index} = source
    @body    = Block.wrap [body]
    @own     = !!source.own
    @object  = !!source.object
    @from    = !!source.from
    @index.error 'cannot use index with for-from' if @from and @index
    source.ownTag.error "cannot use own with for-#{if @from then 'from' else 'in'}" if @own and not @object
    [@name, @index] = [@index, @name] if @object
    @index.error 'index cannot be a pattern matching expression' if @index instanceof Value
    @range   = @source instanceof Value and @source.base instanceof Range and not @source.properties.length and not @from
    @pattern = @name instanceof Value
    @index.error 'indexes do not apply to range loops' if @range and @index
    @name.error 'cannot pattern match over range loops' if @range and @pattern
    @returns = false

  children: ['body', 'source', 'guard', 'step']

  # Welcome to the hairiest method in all of CoffeeScript. Handles the inner
  # loop, filtering, stepping, and result saving for array, object, and range
  # comprehensions. Some of the generated code can be shared in common, and
  # some cannot.
  compileNode: (o) ->
    body        = Block.wrap [@body]
    [..., last] = body.expressions
    @returns    = no if last?.jumps() instanceof Return
    source      = if @range then @source.base else @source
    scope       = o.scope
    name        = @name  and (@name.compile o, LEVEL_LIST) if not @pattern
    index       = @index and (@index.compile o, LEVEL_LIST)
    scope.find(name)  if name and not @pattern
    scope.find(index) if index
    rvar        = scope.freeVariable 'results' if @returns
    if @from
      ivar = scope.freeVariable 'x', single: true if @pattern
    else
      ivar = (@object and index) or scope.freeVariable 'i', single: true
    kvar        = ((@range or @from) and name) or index or ivar
    kvarAssign  = if kvar isnt ivar then "#{kvar} = " else ""
    if @step and not @range
      [step, stepVar] = @cacheToCodeFragments @step.cache o, LEVEL_LIST, isComplexOrAssignable
      stepNum   = Number stepVar if @step.isNumber()
    name        = ivar if @pattern
    varPart     = ''
    guardPart   = ''
    defPart     = ''
    idt1        = @tab + TAB
    if @range
      forPartFragments = source.compileToFragments merge o,
        {index: ivar, name, @step, isComplex: isComplexOrAssignable}
    else
      svar    = @source.compile o, LEVEL_LIST
      if (name or @own) and @source.unwrap() not instanceof IdentifierLiteral
        defPart    += "#{@tab}#{ref = scope.freeVariable 'ref'} = #{svar};\n"
        svar       = ref
      if name and not @pattern and not @from
        namePart   = "#{name} = #{svar}[#{kvar}]"
      if not @object and not @from
        defPart += "#{@tab}#{step};\n" if step isnt stepVar
        down = stepNum < 0
        lvar = scope.freeVariable 'len' unless @step and stepNum? and down
        declare = "#{kvarAssign}#{ivar} = 0, #{lvar} = #{svar}.length"
        declareDown = "#{kvarAssign}#{ivar} = #{svar}.length - 1"
        compare = "#{ivar} < #{lvar}"
        compareDown = "#{ivar} >= 0"
        if @step
          if stepNum?
            if down
              compare = compareDown
              declare = declareDown
          else
            compare = "#{stepVar} > 0 ? #{compare} : #{compareDown}"
            declare = "(#{stepVar} > 0 ? (#{declare}) : #{declareDown})"
          increment = "#{ivar} += #{stepVar}"
        else
          increment = "#{if kvar isnt ivar then "++#{ivar}" else "#{ivar}++"}"
        forPartFragments = [@makeCode("#{declare}; #{compare}; #{kvarAssign}#{increment}")]
    if @returns
      resultPart   = "#{@tab}#{rvar} = [];\n"
      returnResult = "\n#{@tab}return #{rvar};"
      body.makeReturn rvar
    if @guard
      if body.expressions.length > 1
        body.expressions.unshift new If (new Parens @guard).invert(), new StatementLiteral "continue"
      else
        body = Block.wrap [new If @guard, body] if @guard
    if @pattern
      body.expressions.unshift new Assign @name, if @from then new IdentifierLiteral kvar else new Literal "#{svar}[#{kvar}]"
    defPartFragments = [].concat @makeCode(defPart), @pluckDirectCall(o, body)
    varPart = "\n#{idt1}#{namePart};" if namePart
    if @object
      forPartFragments = [@makeCode("#{kvar} in #{svar}")]
      guardPart = "\n#{idt1}if (!#{utility 'hasProp', o}.call(#{svar}, #{kvar})) continue;" if @own
    else if @from
      forPartFragments = [@makeCode("#{kvar} of #{svar}")]
    bodyFragments = body.compileToFragments merge(o, indent: idt1), LEVEL_TOP
    if bodyFragments and bodyFragments.length > 0
      bodyFragments = [].concat @makeCode("\n"), bodyFragments, @makeCode("\n")
    [].concat defPartFragments, @makeCode("#{resultPart or ''}#{@tab}for ("),
      forPartFragments, @makeCode(") {#{guardPart}#{varPart}"), bodyFragments,
      @makeCode("#{@tab}}#{returnResult or ''}")

  pluckDirectCall: (o, body) ->
    defs = []
    for expr, idx in body.expressions
      expr = expr.unwrapAll()
      continue unless expr instanceof Call
      val = expr.variable?.unwrapAll()
      continue unless (val instanceof Code) or
                      (val instanceof Value and
                      val.base?.unwrapAll() instanceof Code and
                      val.properties.length is 1 and
                      val.properties[0].name?.value in ['call', 'apply'])
      fn    = val.base?.unwrapAll() or val
      ref   = new IdentifierLiteral o.scope.freeVariable 'fn'
      base  = new Value ref
      if val.base
        [val.base, base] = [base, val]
      body.expressions[idx] = new Call base, expr.args
      defs = defs.concat @makeCode(@tab), (new Assign(ref, fn).compileToFragments(o, LEVEL_TOP)), @makeCode(';\n')
    defs

#### Switch

# A JavaScript *switch* statement. Converts into a returnable expression on-demand.
exports.Switch = class Switch extends Base
  constructor: (@subject, @cases, @otherwise) ->

  children: ['subject', 'cases', 'otherwise']

  isStatement: YES

  jumps: (o = {block: yes}) ->
    for [conds, block] in @cases
      return jumpNode if jumpNode = block.jumps o
    @otherwise?.jumps o

  makeReturn: (res) ->
    pair[1].makeReturn res for pair in @cases
    @otherwise or= new Block [new Literal 'void 0'] if res
    @otherwise?.makeReturn res
    this

  compileNode: (o) ->
    idt1 = o.indent + TAB
    idt2 = o.indent = idt1 + TAB
    fragments = [].concat @makeCode(@tab + "switch ("),
      (if @subject then @subject.compileToFragments(o, LEVEL_PAREN) else @makeCode "false"),
      @makeCode(") {\n")
    for [conditions, block], i in @cases
      for cond in flatten [conditions]
        cond  = cond.invert() unless @subject
        fragments = fragments.concat @makeCode(idt1 + "case "), cond.compileToFragments(o, LEVEL_PAREN), @makeCode(":\n")
      fragments = fragments.concat body, @makeCode('\n') if (body = block.compileToFragments o, LEVEL_TOP).length > 0
      break if i is @cases.length - 1 and not @otherwise
      expr = @lastNonComment block.expressions
      continue if expr instanceof Return or (expr instanceof Literal and expr.jumps() and expr.value isnt 'debugger')
      fragments.push cond.makeCode(idt2 + 'break;\n')
    if @otherwise and @otherwise.expressions.length
      fragments.push @makeCode(idt1 + "default:\n"), (@otherwise.compileToFragments o, LEVEL_TOP)..., @makeCode("\n")
    fragments.push @makeCode @tab + '}'
    fragments

#### If

# *If/else* statements. Acts as an expression by pushing down requested returns
# to the last line of each clause.
#
# Single-expression **Ifs** are compiled into conditional operators if possible,
# because ternaries are already proper expressions, and don't need conversion.
exports.If = class If extends Base
  constructor: (condition, @body, options = {}) ->
    @condition = if options.type is 'unless' then condition.invert() else condition
    @elseBody  = null
    @isChain   = false
    {@soak}    = options

  children: ['condition', 'body', 'elseBody']

  bodyNode:     -> @body?.unwrap()
  elseBodyNode: -> @elseBody?.unwrap()

  # Rewrite a chain of **Ifs** to add a default case as the final *else*.
  addElse: (elseBody) ->
    if @isChain
      @elseBodyNode().addElse elseBody
    else
      @isChain  = elseBody instanceof If
      @elseBody = @ensureBlock elseBody
      @elseBody.updateLocationDataIfMissing elseBody.locationData
    this

  # The **If** only compiles into a statement if either of its bodies needs
  # to be a statement. Otherwise a conditional operator is safe.
  isStatement: (o) ->
    o?.level is LEVEL_TOP or
      @bodyNode().isStatement(o) or @elseBodyNode()?.isStatement(o)

  jumps: (o) -> @body.jumps(o) or @elseBody?.jumps(o)

  compileNode: (o) ->
    if @isStatement o then @compileStatement o else @compileExpression o

  makeReturn: (res) ->
    @elseBody  or= new Block [new Literal 'void 0'] if res
    @body     and= new Block [@body.makeReturn res]
    @elseBody and= new Block [@elseBody.makeReturn res]
    this

  ensureBlock: (node) ->
    if node instanceof Block then node else new Block [node]

  # Compile the `If` as a regular *if-else* statement. Flattened chains
  # force inner *else* bodies into statement form.
  compileStatement: (o) ->
    child    = del o, 'chainChild'
    exeq     = del o, 'isExistentialEquals'

    if exeq
      return new If(@condition.invert(), @elseBodyNode(), type: 'if').compileToFragments o

    indent   = o.indent + TAB
    cond     = @condition.compileToFragments o, LEVEL_PAREN
    body     = @ensureBlock(@body).compileToFragments merge o, {indent}
    ifPart   = [].concat @makeCode("if ("), cond, @makeCode(") {\n"), body, @makeCode("\n#{@tab}}")
    ifPart.unshift @makeCode @tab unless child
    return ifPart unless @elseBody
    answer = ifPart.concat @makeCode(' else ')
    if @isChain
      o.chainChild = yes
      answer = answer.concat @elseBody.unwrap().compileToFragments o, LEVEL_TOP
    else
      answer = answer.concat @makeCode("{\n"), @elseBody.compileToFragments(merge(o, {indent}), LEVEL_TOP), @makeCode("\n#{@tab}}")
    answer

  # Compile the `If` as a conditional operator.
  compileExpression: (o) ->
    cond = @condition.compileToFragments o, LEVEL_COND
    body = @bodyNode().compileToFragments o, LEVEL_LIST
    alt  = if @elseBodyNode() then @elseBodyNode().compileToFragments(o, LEVEL_LIST) else [@makeCode('void 0')]
    fragments = cond.concat @makeCode(" ? "), body, @makeCode(" : "), alt
    if o.level >= LEVEL_COND then @wrapInBraces fragments else fragments

  unfoldSoak: ->
    @soak and this

# Constants
# ---------

UTILITIES =

  # Correctly set up a prototype chain for inheritance, including a reference
  # to the superclass for `super()` calls, and copies of any static properties.
  extend: (o) -> "
    function(child, parent) {
      for (var key in parent) {
        if (#{utility 'hasProp', o}.call(parent, key)) child[key] = parent[key];
      }
      function ctor() {
        this.constructor = child;
      }
      ctor.prototype = parent.prototype;
      child.prototype = new ctor();
      child.__super__ = parent.prototype;
      return child;
    }
  "

  # Create a function bound to the current value of "this".
  bind: -> '
    function(fn, me){
      return function(){
        return fn.apply(me, arguments);
      };
    }
  '

  # Discover if an item is in an array.
  indexOf: -> "
    [].indexOf || function(item) {
      for (var i = 0, l = this.length; i < l; i++) {
        if (i in this && this[i] === item) return i;
      }
      return -1;
    }
  "

  modulo: -> """
    function(a, b) { return (+a % (b = +b) + b) % b; }
  """

  # Shortcuts to speed up the lookup time for native functions.
  hasProp: -> '{}.hasOwnProperty'
  slice  : -> '[].slice'

# Levels indicate a node's position in the AST. Useful for knowing if
# parens are necessary or superfluous.
LEVEL_TOP    = 1  # ...;
LEVEL_PAREN  = 2  # (...)
LEVEL_LIST   = 3  # [...]
LEVEL_COND   = 4  # ... ? x : y
LEVEL_OP     = 5  # !...
LEVEL_ACCESS = 6  # ...[0]

# Tabs are two spaces for pretty printing.
TAB = '  '

SIMPLENUM = /^[+-]?\d+$/

# Helper Functions
# ----------------

# Helper for ensuring that utility functions are assigned at the top level.
utility = (name, o) ->
  {root} = o.scope
  if name of root.utilities
    root.utilities[name]
  else
    ref = root.freeVariable name
    root.assign ref, UTILITIES[name] o
    root.utilities[name] = ref

multident = (code, tab) ->
  code = code.replace /\n/g, '$&' + tab
  code.replace /\s+$/, ''

isLiteralArguments = (node) ->
  node instanceof IdentifierLiteral and node.value is 'arguments'

isLiteralThis = (node) ->
  node instanceof ThisLiteral or
    (node instanceof Code and node.bound) or
    node instanceof SuperCall

isComplexOrAssignable = (node) -> node.isComplex() or node.isAssignable?()

# Unfold a node's child if soak, then tuck the node under created `If`
unfoldSoak = (o, parent, name) ->
  return unless ifn = parent[name].unfoldSoak o
  parent[name] = ifn.body
  ifn.body = new Value parent
  ifn
