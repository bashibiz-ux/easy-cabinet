module KitchenCabinet
  class UIController
    def initialize(manager)
      @manager = manager
      @dialog = nil
    end

    def show
      unless @dialog
        path = File.join(File.dirname(__FILE__), 'ui', 'index.html')
        @dialog = UI::HtmlDialog.new(dialog_title: 'Kitchen Cabinet Generator', preferences_key: 'KitchenCabinetGenerator', scrollable: true, resizable: true, width: 420, height: 800, style: UI::HtmlDialog::STYLE_DIALOG)
        @dialog.set_file(path)
        bind_callbacks
        @dialog.set_on_closed { @dialog = nil }
      end
      @dialog.show
      refresh
    end

    def bind_callbacks
      @dialog.add_action_callback('ready') { |_d,_| refresh }
      @dialog.add_action_callback('insert') { |_d,json| perform { @manager.create(JSON.parse(json)); refresh } }
      @dialog.add_action_callback('update') { |_d,json| perform { inst = @manager.selected_cabinet; raise 'Select a parametric cabinet.' unless inst; @manager.update(inst, JSON.parse(json)); refresh } }
      @dialog.add_action_callback('duplicate') { |_d,_| perform { @manager.duplicate(@manager.selected_cabinet); refresh } }
      @dialog.add_action_callback('delete') { |_d,_| perform { @manager.delete(@manager.selected_cabinet); refresh } }
      @dialog.add_action_callback('select') { |_d,id| perform { inst = @manager.all_cabinets.find { |i| i.definition.get_attribute(CabinetManager::DICT, 'cabinet_id') == id }; @manager.select(inst); refresh } }
      @dialog.add_action_callback('open_door') { |_d,_| perform { @manager.animate_doors(@manager.selected_cabinet, true); refresh } }
      @dialog.add_action_callback('close_door') { |_d,_| perform { @manager.animate_doors(@manager.selected_cabinet, false); refresh } }
      @dialog.add_action_callback('refresh') { |_d,_| refresh }
    end

    def perform
      yield
    rescue => e
      UI.messagebox(e.message)
      refresh
    end

    def load_instance(instance)
      return refresh unless @dialog && instance
      data = @manager.params_for(instance) || CabinetGenerator.defaults
      payload = { params: data, id: instance.definition.get_attribute(CabinetManager::DICT, 'cabinet_id'), cabinets: cabinet_list, materials: @manager.materials }
      @dialog.execute_script("window.loadCabinet(#{JSON.generate(payload)});")
    end

    def selection_cleared
      @dialog&.execute_script('window.selectionCleared();')
    end

    def cabinet_list
      @manager.all_cabinets.map do |i|
        { id: i.definition.get_attribute(CabinetManager::DICT, 'cabinet_id'), params: @manager.params_for(i) }
      end
    end

    def refresh
      return unless @dialog
      inst = @manager.selected_cabinet
      payload = { params: inst ? @manager.params_for(inst) : CabinetGenerator.defaults, id: inst ? inst.definition.get_attribute(CabinetManager::DICT, 'cabinet_id') : nil, cabinets: cabinet_list, materials: @manager.materials }
      @dialog.execute_script("window.loadCabinet(#{JSON.generate(payload)});")
    end
  end
end
