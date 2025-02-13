request = require 'request'

sentry  = require './sentry'
librato = require './librato'

module.exports = (task, cb) ->
  task.from.url = getTaskFromUrl task
  task.to.url = getTaskToUrl task

  if --task.retries is 0
    sentry.captureMessage "Retries exceeded for #{task.from.type}:#{task.from.id}",
      level: 'error'
      extra: task: task

    task = undefined
    return cb()

  if task.method is 'delete'
    return request.del url: task.to.url, (err, res, body) ->
      log 'delete', task, res, body, err

      if err
        task.errors.push "DELETE from NTB returned #{err.code}"
        module.parent.exports.queue.push task

        err = res = body = undefined
        return cb()

      if res.statusCode not in [404, 204]
        task.errors.push "DELETE from NTB returned #{res.statusCode}"
        module.parent.exports.queue.push task

        sentry.captureMessage "DELETE failed for #{task.from.type}:#{task.from.id}",
          level: 'error'
          extra: task: task, body: body, status: res.statusCode

        err = res = body = undefined
        return cb()

      err = res = body = undefined
      return cb()

    # Handle ETIMEDOUT error
    .on 'error', (err) ->
      task.errors.push err

      sentry.captureMessage "DELETE to NTB for #{task.from.type}:#{task.from.id} failed",
        level: 'error'
        extra: task: task, error: err

      err = undefined
      return cb()

  # Get item from Sherpa 2
  request.get url: task.from.url, json: true, (err, res, doc) ->
    log 'get', task, res, doc, err

    if err
      task.errors.push "GET from sherpa2 returned #{err.code}"
      module.parent.exports.queue.push task

      err = res = body = undefined
      return cb()

    if not doc or typeof doc isnt 'object' or Object.keys(doc).length is 0
      task.errors.push "GET from sherpa2 returned no body"
      module.parent.exports.queue.push task

      err = res = body = undefined
      return cb()

    if res.statusCode is 404
      err = res = body = undefined
      return cb()

    if res.statusCode isnt 200
      task.errors.push "GET from sherpa2 returned #{res.statusCode}"
      module.parent.exports.queue.push task

      err = res = body = undefined
      return cb()

    # Update item in Nasjonal Turbase
    request[task.method] url: task.to.url, json: true, body: doc, (err, res, body) ->
      log task.method, task, res, body, err

      if err
        task.errors.push "#{task.method} to NTB returned #{err.code}"
        module.parent.exports.queue.push task

        err = res = body = undefined
        return cb()

      if res.statusCode not in [200, 201]
        task.errors.push "#{task.method} to NTB returned #{res.statusCode}"

        # 422 is returned when the data standard validation failes. We can
        # not recover from this so this should be propperly logged to Sentry.

        if res.statusCode is 422
          task.errors.push body.message if body?.message

          sentry.captureMessage "Validation failed for #{task.from.type}:#{task.from.id}",
            level: 'error'
            extra: task: task, body: body, status: res.statusCode

          err = res = body = undefined
          return cb()

        # 501 is returned when the API does not support PUT. Do a POST
        # instead.

        # 404 is returned when a document has been deleted or does not exist. Do
        # a POST instead.

        if task.method is 'put' and res.statusCode in [404, 501]
          module.parent.exports.queue.unshift task
          task.method = 'post'

          err = res = body = undefined
          return cb()

        # 500 for a POST is most certainly a duplicate key error. We can not
        # recover from this so this should be propperly logged to Sentry.

        if task.method is 'post' and res.statusCode is 500
          task.errors.push body.message if body?.message

          sentry.captureMessage "POST failed for #{task.from.type}:#{task.from.id}",
            level: 'error'
            extra: task: task, body: body, status: res.statusCode

          err = res = body = undefined
          return cb()

        module.parent.exports.queue.push task

        err = res = body = undefined
        return cb()

      if doc.bilder and doc.bilder.length > 0
        for id in doc.bilder
          module.parent.exports.queue.unshift
            retries: 5
            errors: []
            method: 'put'
            from: id: id, type: 'image'
            to: id: id, type: 'bilder'

      err = res = body = undefined
      return cb()

    # Handle ETIMEDOUT error for NTB request
    .on 'error', (err) ->
      task.errors.push err

      sentry.captureMessage "#{task.method} to NTB for #{task.from.type}:#{task.from.id} failed",
        level: 'error'
        extra: task: task, error: err

      err = undefined
      return cb()

  # Handle ETIMEDOUT error Sherpa request
  .on 'error', (err) ->
    task.errors.push err

    sentry.captureMessage "GET from Sherpa for #{task.from.type}:#{task.from.id} failed",
      level: 'error'
      extra: task: task, error: err

    err = undefined
    return cb()

log = (method, task, res, doc, err) ->
  return if process.env.SILENT is 'true'

  if method is 'get'
    console.log res?.statusCode, method.toUpperCase(), task.from.url
  else
    librato.measure 'http.ntb.request', 1, source: method
    librato.measure 'http.ntb.response', 1, source: res?.statusCode + ''
    librato.measure 'http.ntb.error', 1, source: err.code if err and err.code

    console.log res?.statusCode, method.toUpperCase(), task.to.url

  console.error err if err

getTaskFromUrl = (task) ->
  url = process.env.SH2_API_URL
  key = process.env.SH2_API_KEY

  return url + task.from.type + '/' + task.from.id + '/?api_key=' + key

getTaskToUrl = (task) ->
  url = process.env.NTB_API_URL
  key = process.env.NTB_API_KEY

  if task.method isnt 'post'
    return url + task.to.type + '/' + task.to.id + '/?api_key=' + key
  else
    return url + task.to.type + '/?api_key=' + key

