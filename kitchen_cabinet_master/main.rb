# frozen_string_literal: true

require 'sketchup.rb'
require 'json'

module KitchenCabinetMaster
  PLUGIN_DIR = File.dirname(__FILE__).freeze
  DATA_DIR   = File.join(PLUGIN_DIR, 'data').freeze
  HTML_DIR   = File.join(PLUGIN_DIR, 'html').freeze

  # Load order matters: Response/Defaults first, UI layer last.
  require_relative 'response'
  require_relative 'defaults'
  require_relative 'attribute_manager'
  require_relative 'validation_manager'
  require_relative 'material_manager'
  require_relative 'catalog_manager'
  require_relative 'cabinet_layout'
  require_relative 'toe_kick'
  require_relative 'part_layout'
  require_relative 'door_animation'
  require_relative 'drawer_animation'
  require_relative 'handle_manager'
  require_relative 'panel_generator'
  require_relative 'cabinet_generator'
  require_relative 'part_generator'
  require_relative 'selection_manager'
  require_relative 'snap_manager'
  require_relative 'naming_manager'
  require_relative 'placement_manager'
  require_relative 'cabinet_manager'
  require_relative 'part_manager'
  require_relative 'dialog_manager'

  unless file_loaded?(__FILE__)
    SelectionManager.install
    SnapManager.install
    menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    menu.add_item('Open Control Panel') { DialogManager.show }
    snap_item = menu.add_item('Snap Moved Cabinets to Neighbours and Walls') { SnapManager.enabled = !SnapManager.enabled? }
    menu.set_validation_proc(snap_item) { SnapManager.enabled? ? MF_CHECKED : MF_UNCHECKED }
    icons = File.join(PLUGIN_DIR, 'icons')
    open_cmd = UI::Command.new('Kitchen Cabinet Master') { DialogManager.show }
    open_cmd.tooltip = 'Kitchen Cabinet Master'
    open_cmd.status_bar_text = 'Open the Kitchen Cabinet Master control panel'
    open_cmd.small_icon = File.join(icons, 'icon_24.png')
    open_cmd.large_icon = File.join(icons, 'icon_32.png')
    toolbar = UI::Toolbar.new(EXTENSION_NAME)
    toolbar.add_item(open_cmd)
    toolbar.show
    file_loaded(__FILE__)
  end
end
