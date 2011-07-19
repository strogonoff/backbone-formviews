###
A global object responsible for displaying confirmation messages
and stuff like that.
###
UI = window.UI


class FormView extends Backbone.RenderableView
  events:
    'submit form': 'handle_submit'
    'click .submit': 'handle_submit'
    'click .cancel': 'handle_cancel'

  formSelector: 'form'

  ###
  Allows handling multiple forms per HTML document,
  gives uniqueness to their ids.
  ###
  formPrefix: ''

  ###
  Templates are expected to be requireable like this.
  (Using brunch allows for that.)
  ###
  fieldTemplate: require('templates/forms/field')
  fields: []

  get_form: => @$(@formSelector)

  # Validation UI
  clear_validation_errors: -> @get_form().find('li.error').remove()
  display_validation_errors: (errors) ->
    form = @get_form()
    #console.debug "Validation errors:", errors
    @clear_validation_errors()
    _.each errors, (field_errors, field) ->
      row = $("[name='#{field}']", form).parent('.field-row')
      #errors = $("<ul class='errorlist'></ul>").appendTo row
      _.each field_errors, (error) ->
        #log "Error for field #{field}: #{error}"
        $("<li class='error'>#{error}</li>").insertAfter(row)

  # Hooks
  finish_editing: ->
  cancel_editing: ->
  prepare_submit: -> {} # If returns false, submission is aborted

  # Request opts
  get_submit_type: -> return 'POST'
  get_submit_data: -> @get_form().serializeObject()
  get_submit_request_opts: (data) ->
    complete = (xhr, status) =>
      #console.debug "Submit request completed", xhr, status
      resp = $.parseJSON xhr.responseText
      if status == 'success'
        @finish_editing resp
      else
        if resp.traceback?
          UI.error gettext "Server error happened! Please contact admin."
          console.error "Server error: %o", resp
        else
          # If no traceback, assuming it's just validation problem.
          @display_validation_errors(resp)
    ajaxOpts =
      type: @get_submit_type()
      data: JSON.stringify(data)
      url: @get_form().attr('action')
      dataType: 'json'
      contentType: 'application/json'
      complete: complete
    return ajaxOpts

  # Events
  handle_submit: (e) =>
    e.preventDefault; e.stopPropagation()

    $.when(@get_submit_data(), @prepare_submit()).done((data) =>
      if data == false then return false
      $.ajax @get_submit_request_opts(data)
      @cleanup()
    ).fail(->
      UI.error gettext "Failed to submit the form!"
      console.error "Failed to prepare submit"
    )

  handle_cancel: (e) =>
    e.preventDefault(); e.stopPropagation()
    @cleanup()
    @cancel_editing()

  cleanup: => @clear_validation_errors()

  get_context_helpers: ->
    _.extend {}, super,
      include_field: (opts) =>
        # Options: name value [placeholder] [required]
        opts.model = @model || null
        opts.prefix = @formPrefix
        if opts.name in @fields
          return @fieldTemplate(opts)
        else
          return ""

  get_context_data: ->
    _.extend {}, super,
      url: @get_form_action_url()
      prefix: @formPrefix

  get_form_action_url: -> ""


class FormWithRelationsView extends FormView
  relatedFieldTemplate: require('templates/forms/related_field')
  relatedFields: {}
  relatedFieldsAutoCreateBy: {}

  get_context_helpers: ->
    _.extend {}, super,
      include_related_field: (opts) =>
        opts.choices = @relatedFields[opts.name]
        opts.prefix = @formPrefix
        return @relatedFieldTemplate(opts)

  get_context_data: ->
    context = super
    _.each @relatedFields, (collection, field) ->
      context["#{field}_choices"] = collection
    return context

  get_submit_data: ->
    data = super
    return $.Deferred((dfd) =>
      $.when(
        @auto_create_related_objects(data)
      ).then((data) ->
        dfd.resolve(data)
      )
    ).promise()

  post_render: (dfd, opts) ->
    @enable_comboboxes_for_related_fields()
    dfd?.resolve()

  auto_create_related_objects: (data) ->
    # This beast checks if in autocomplete inputs for related fields
    # are entered not existing values, and creates corresponding objects.
    # It's done only if model can be created from what's entered in the input
    # (i.e. only one field is necessary for object to be created).
    # This is controlled by relatedFieldsAutoCreateBy option.

    form = @get_form()

    result = data
    total = _.keys(@relatedFields).length

    dfd = $.Deferred()
    promises = []

    _.each @relatedFields, (collection, field) =>
      if result == false then return false

      # TODO: make a check, so that not all related fields are autocreateable.
      create_by_field = @relatedFieldsAutoCreateBy[field]
      select = form.find("select[name=\"#{field}\"]")
      selected_option = select.find("option[selected]").first()
      input = select.parents('.field-row').find('input.ui-autocomplete-input').first()

      entered = input.val()
      selected = selected_option.text()

      if selected != entered and entered != ""
        results = collection.filter((el) -> el.get(create_by_field) == entered)
        if results.length == 1
          #console.debug "Existing #{field}", results[0]
          result[field] = results[0].get('resource_uri')
        else if results.length == 0 and confirm(gettext("Create new #{field} \"#{entered}\"?"))
          opts = {}
          opts[create_by_field] = entered
          new_obj = new collection.model(opts)
          #console.debug "Creating new #{field} #{entered}"
          new_promise = new_obj.save {},
            success: (model, response) ->
              #console.debug "Saved new #{field}", model
              result[field] = model.get('resource_uri')
            error: (model, response) ->
              #console.error "Error saving #{field}", model
          promises.push new_promise
        else
          #console.debug "Too many results or no confirmation"
          result = false

    $.when.apply($, promises).then(->
      dfd.resolve(result)
    )
    return dfd.promise()

  enable_comboboxes_for_related_fields: ->
    # Place this in post_render().
    #console.log "comboboxing"
    _.each @relatedFields, (collection, field) =>
      resp = @$("#id_#{@formPrefix}#{field}").combobox()
      #console.log 'boxing', field, collection, resp


class MultipleModelFormView extends FormWithRelationsView
  ###
  Defines which fields should not be editable in multiple model form.
  (Fields like identification numbers should go here.)
  An array of form field names.
  ###
  uniqueFields: []

  post_render: (dfd, opts) ->
    super(null) # null prevents super from resolving deferred
    @insert_checkboxes()
    dfd?.resolve()

  # FormView
  get_submit_type: -> 'PUT'

  get_form_action_url: -> @collection.url

  handle_submit: (e) =>
    e.preventDefault; e.stopPropagation()
    $.when(@get_submit_data(), @prepare_submit()).done((data) =>
      @cleanup()

      # Strip enabled checkboxes data, passing only data for checked fields
      enabled_fields = @get_enabled_field_names()
      disabled_fields = @get_disabled_field_names()
      console.debug "Fields: %o, %o", enabled_fields, disabled_fields

      common_data = {}
      _.each data, (value, field) ->
        if _(enabled_fields).indexOf(field) != -1
          common_data[field] = value

      #console.debug "Common data: %o", common_data
      # Update items.
      # Need to FUCKING OPTIMIZE this.
      _.each @models, (item) =>
        opts = @get_submit_request_opts()

        # Append unique item data to the common data
        item_data = _.extend {}, common_data
        for field in @uniqueFields
          item_data[field] = item.get(field)
        for field in disabled_fields
          item_data[field] = item.get(field)
        console.debug 'Item data', item, item_data

        opts.data = JSON.stringify(item_data)
        opts.url = item.get 'resource_uri'
        opts.complete = (xhr, status) =>
          if status == 'success'
            console.log "Updated item #{item.get('inv_no')}"; item.fetch()
          else
            @display_validation_errors(xhr.responseText)
        $.ajax opts
    ).fail(() ->
      UI.error gettext "Failed to prepare form"
      console.error "Failed to prepare to submit form"
    )

  get_context_data: ->
    # Determine common values for items
    _.extend {}, super,
      models: @models
      common_data: @get_common_data()

  ###
  For each field that is not unique, we check if it contains
  the same value in all selected models. If it does, we add
  it to the common data that will used to pre-fill fields.
  ###
  get_common_data: ->
    common_data = {}
    args = [@fields]
    _.each(_.flatten([@uniqueFields]), (e) -> args.push(e))
    _.each _.without.apply(null, args), (field) =>
      values = []
      _.each @models, (obj) -> values.push obj.get field
      unique = _.uniq values
      if unique.length == 1
        common_data[field] = unique[0]
    return comon_data

  ###
  Enabling and disabling fields:
  ###
  insert_checkboxes: ->
    form = @get_form()
    disabled_fields = @get_disabled_field_names()
    _(@fields).each (field) =>
      input = form.find("[name=#{field}]")
      checkbox = $("<input type=checkbox name=\"enabled-#{field}\">")
      .prependTo input.parents('.field-row')
      # Unique fields cannot be overridden for multiple elements
      if _(@uniqueFields).indexOf(field) != -1
        checkbox.attr(disabled: true)
        input.attr(disabled: true)

  get_enabled_field_names: ->
    data = @get_form().serializeObject()
    return _.map(
      _.select(_.keys(data), (field) -> _(field).startsWith('enabled-')),
      (field) -> field.replace('enabled-', '')
    )

  get_disabled_field_names: ->
    enabled_fields = @get_enabled_field_names()
    return _.select @fields, (field) ->
      _(enabled_fields).indexOf(field) == -1 and not _(field).startsWith('enabled-')

  # Models
  models: null
  set_models: (models) =>
    #console.debug "Setting models", models
    if @models then @unset_models()
    @models = models
    @

  unset_models: =>
    @models = null
    @


class ModelFormView extends FormWithRelationsView
  fieldTemplate: require('templates/forms/model_field')

  get_submit_type: -> if @model.isNew() then 'POST' else 'PUT'

  get_form_action_url: =>
    if @model.isNew()
      @model.collection.url
    else
      @model.get 'resource_uri'

  get_context_data: ->
    # Model JSON and model itself
    # are passed to the template by default.
    # Also related fields are added, as <field_name>_choices.
    _.extend {}, super, context, @model.toJSON(),
      model: @model

  get_context_helpers: =>
    _.extend {}, super,
      include_related_field: (opts) =>
        # Override value with model
        opts.value = @model.get opts.name
        opts.choices = @relatedFields[opts.name]
        opts.prefix = @formPrefix
        return @relatedFieldTemplate(opts)

  # Models
  model: null
  set_model: (model) =>
    #console.debug "Setting model"
    if @model then @unset_model()
    model.bind 'change', @render
    @model = model
    @

  unset_model: =>
    @model.unbind @render
    #@model = null
    @


Backbone = window.Backbone
Backbone.ModelFormView = ModelFormView
Backbone.MultipleModelFormView = MultipleModelFormView
Backbone.FormWithRelationsView = FormWithRelationsView
Backbone.FormView = FormView
