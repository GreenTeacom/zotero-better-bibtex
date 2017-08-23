debug = require('./debug.coffee')
flash = require('./flash.coffee')
co = Zotero.Promise.coroutine
events = require('./events.coffee')
getItemsAsync = require('./get-items-async.coffee')

Prefs = require('./preferences.coffee')
Citekey = require('./keymanager/get-set.coffee')
DB = require('./db/main.coffee')
Formatter = require('./keymanager/formatter.coffee')

debug('KeyManager: loading...', Object.keys(Formatter))

class KeyManager
  pin: co((id) ->
    debug('KeyManager.pin', id)
    item = yield getItemsAsync(id)
    citekey = Citekey.get(item.getField('extra'))
    return if citekey.pinned

    citekey = @keys.update(item)
    item.setField('extra', Citekey.set(citekey.extra, citekey))
    item.saveTx()
    return
  )

  unpin: co((id) ->
    debug('KeyManager.pin', id)
    item = yield getItemsAsync(id)
    citekey = Citekey.get(item.getField('extra'))
    return unless citekey.pinned

    item.setField('extra', citekey.extra) # citekey is stripped here but will be regenerated by the notifier
    item.saveTx()
    return
  )

  refresh: co((id) ->
    debug('KeyManager.refresh', id)
    item = yield getItemsAsync(id)
    citekey = Citekey.get(item.getField('extra'))
    debug('KeyManager.refresh?', id, citekey)
    return if citekey.pinned

    @update(item)
    return
  )

  init: co(->
    debug('KeyManager.init...')

    @keys = DB.getCollection('citekey')

    @query = {
      field: {}
      type: {}
    }

    for field in yield Zotero.DB.queryAsync("select fieldID, fieldName from fields where fieldName in ('extra')")
      @query.field[field.fieldName] = field.fieldID
    for type in yield Zotero.DB.queryAsync("select itemTypeID, typeName from itemTypes where typeName in ('note', 'attachment')") # 1, 14
      @query.type[type.typeName] = type.itemTypeID

    Formatter.update()

    yield @rescan()

    debug('KeyManager.init: done')

    events.on('preference-changed', (pref) ->
      debug('KeyManager.pref changed', pref)
      if pref in ['autoAbbrevStyle', 'citekeyFormat', 'citekeyFold', 'skipWords']
        Formatter.update()
      return
    )

    return
  )

  remaining: (start, done, total) ->
    remaining = (total - done) / (done / ((new Date()) - start))

    date = new Date(remaining)

    hh = date.getUTCHours()
    mm = date.getMinutes()
    ss = date.getSeconds()

    hh = "0#{hh}" if hh < 10
    mm = "0#{mm}" if mm < 10
    ss = "0#{ss}" if ss < 10

    return "#{done} / #{total}, #{hh}:#{mm}:#{ss} remaining"

  rescan: co((clean)->
    if @scanning
      if Array.isArray(@scanning)
        left = ", #{@scanning.length} items left"
      else
        left = ''
      flash('Scanning still in progress', "Scan is still running#{left}")
      return

    @scanning = true

    flash('Scanning', 'Scanning for references without citation keys. If you have a large library, this may take a while', 1)

    @keys.removeDataOnly() if clean

    items = yield Zotero.DB.queryAsync("""
      SELECT item.itemID, item.libraryID, extra.value as extra, item.itemTypeID
      FROM items item
      LEFT JOIN itemData field ON field.itemID = item.itemID AND field.fieldID = #{@query.field.extra}
      LEFT JOIN itemDataValues extra ON extra.valueID = field.valueID
      WHERE item.itemID NOT IN (select itemID from deletedItems)
      AND item.itemTypeID NOT IN (#{@query.type.attachment}, #{@query.type.note})
    """)
    for item in items
      # if no citekey is found, it will be '', which will allow it to be found right after this loop
      citekey = Citekey.get(item.extra)
      @keys.findAndRemove({ itemID: item.itemID }) if !clean && citekey.pinned
      @keys.insert(Object.assign(citekey, { itemID: item.itemID, libraryID: item.libraryID })) if clean || !@keys.findOne({ itemID: item.itemID })

    # find all references without citekey
    @scanning = @keys.find({ citekey: '' })

    if @scanning.length != 0
      progressWin = new Zotero.ProgressWindow({ closeOnClick: false })
      progressWin.changeHeadline('Better BibTeX: Assigning citation keys')
      progressWin.addDescription("Found #{@scanning.length} references without a citation key")
      icon = "chrome://zotero/skin/treesource-unfiled#{if Zotero.hiDPI then '@2x' else ''}.png"
      progress = new progressWin.ItemProgress(icon, "Assigning citation keys")
      progressWin.show()

      start = new Date()
      for key, done in @scanning
        try
          item = yield getItemsAsync(key.itemID)
        catch err
          debug('KeyManager.rescan: getItemsAsync failed:', err)

        try
          @update(item, key)
        catch err
          debug('KeyManager.rescan: update', done, 'failed:', err)

        if done % 10 == 1
          progress.setProgress((done * 100) / @scanning.length)
          progress.setText(@remaining(start, done, @scanning.length))

      progress.setProgress(100)
      progress.setText('Ready')
      progressWin.startCloseTimer(5000)

    @scanning = false

    debug('KeyManager.rescan: done updating citation keys')

    return
  )

  postfixAlpha: (n) ->
    postfix = ''
    a = 1
    b = 26
    while (n -= a) >= 0
      postfix = String.fromCharCode(parseInt(n % b / a) + 97) + postfix
      a = b
      b *= 26
    return postfix

  postfixRE: {
    numeric: /^(-[0-9]+)?$/
    alphabetic: /^([a-z])?$/
  }

  propose: (item) ->
    debug('KeyManager.propose: getting existing key from extra field,if any')
    citekey = Citekey.get(item.getField('extra'))
    debug('KeyManager.propose: found key', citekey)
    citekey.pinned = !!citekey.pinned

    return citekey if citekey.pinned

    debug('KeyManager.propose: formatting...', citekey)
    proposed = Formatter.format(item)
    debug('KeyManager.propose: proposed=', proposed)

    debug("KeyManager.propose: testing whether #{item.id} can keep #{citekey.citekey}")
    # item already has proposed citekey
    if citekey.citekey.slice(0, proposed.citekey.length) == proposed.citekey                                # key begins with proposed sitekey
      re = (proposed.postfix == '0' && @postfixRE.numeric) || @postfixRE.alphabetic
      if citekey.citekey.slice(proposed.citekey.length).match(re)                                           # rest matches proposed postfix
        if @keys.findOne({ libraryID: item.libraryID, citekey: citekey.citekey, itemID: { $ne: item.id } })  # noone else is using it
          return citekey

    debug("KeyManager.propose: testing whether #{item.id} can use proposed #{proposed.citekey}")
    # unpostfixed citekey is available
    if !@keys.findOne({ libraryID: item.libraryID, citekey: proposed.citekey, itemID: { $ne: item.id } })
      debug("KeyManager.propose: #{item.id} can use proposed #{proposed.citekey}")
      return { citekey: proposed.citekey, pinned: false}

    debug("KeyManager.propose: generating free citekey from #{item.id} from", proposed.citekey)
    postfix = 1
    while true
      postfixed = proposed.citekey + (if proposed.postfix == '0' then '-' + postfix else @postfixAlpha(postfix))
      if !@keys.findOne({ libraryID: item.libraryID, citekey: postfixed })
        debug("KeyManager.propose: found <#{postfixed}>")
        return { citekey: postfixed, pinned: false }
      postfix += 1

    # we should never get here
    debug("KeyManager.propose: we should not be here!")
    return null

  update: (item, current) ->
    return if item.isNote() || item.isAttachment()

    current ||= @keys.findOne({ itemID: item.id })
    proposed = @propose(item)

    return current.citekey if current && current.pinned == proposed.pinned && current.citekey == proposed.citekey

    if current
      current.pinned = proposed.pinned
      current.citekey = proposed.citekey
      @keys.update(current)
    else
      @keys.insert({ itemID: item.id, libraryID: item.libraryID, pinned: proposed.pinned, citekey: proposed.citekey })

    return proposed.citekey

   remove: (ids) ->
     ids = [ids] unless Array.isArray(ids)
     @keys.findAndRemove({ itemID : { $in : ids } })
     return

  get: (itemID) ->
    if !@keys
      Zotero.logError(new Error("KeyManager.get called for #{itemID} before init"))
      return { citekey: '', pinned: false }

    return key if key = @keys.findOne({ itemID })

    Zotero.logError(new Error("KeyManager.get called for non-existent #{itemID}"))
    return { citekey: '', pinned: false }


  ### TODO: remove after release ###
  cleanupDynamic: co(->
    items = yield Zotero.DB.queryAsync("""
      select item.itemID, extra.value as extra
      from items item
      join itemData field on field.fieldID = #{@query.field.extra} and field.itemID = item.itemID
      join itemDataValues extra on extra.valueID = field.valueID
      where item.itemTypeID not in (#{@query.type.attachment}, #{@query.type.note})
        and item.itemID not in (select itemID from deletedItems)
        and extra.value like ?
    """, [ '%bibtex*:%' ])
    for item in items
      citekey = Citekey.get(item.extra, true)
      continue if !citekey.citekey || citekey.pinned
      item = yield getItemsAsync(item.itemID)
      item.setField('extra', citekey.extra)
      yield item.saveTx()
    return
  )


debug('KeyManager: loaded', Object.keys(Formatter))

module.exports = new KeyManager()
