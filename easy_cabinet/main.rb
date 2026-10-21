# frozen_string_literal: true

require 'sketchup.rb'
require 'json'

module EasyCabinet
  PLUGIN_DIR = File.dirname(__FILE__).freeze unless const_defined?(:PLUGIN_DIR)
  DATA_DIR   = File.join(PLUGIN_DIR, 'data').freeze unless const_defined?(:DATA_DIR)
  HTML_DIR   = File.join(PLUGIN_DIR, 'html').freeze unless const_defined?(:HTML_DIR)

  # Load order matters: Response/Defaults first, UI layer last. Loaded with Sketchup.require, so the files can be encrypted and signed for the Extension Warehouse.
  CODE_FILES = %w[
    response defaults model_script gola_profile attribute_manager legacy_names validation_manager material_manager catalog_manager my_appliances
    cabinet_layout appliance_parts fixtures customizer toe_kick part_layout door_animation drawer_animation handle_manager
    front_design panel_generator cabinet_generator part_generator selection_manager snap_manager
    naming_manager placement_manager tag_manager custom_door cabinet_manager part_manager worktop_manager wall_bottom_manager kitchen_planner side_exposure dimensioning dimension_manager live_parts island_hood island_back_panel kitchen_manager path_kitchen place_tool feedback_manager layout_scenes room_shell cut_list_manager preset_manager customize_manager dialog_manager
  ].freeze

  def self.load_code
    CODE_FILES.each { |file| Sketchup.require("easy_cabinet/#{file}") }
  end

  load_code

  class << self
    # What the menu item runs.
    def open_panel
      DialogManager.show
    end

    # What the toolbar button runs: the panel opens when it is shut, and shuts when it is open.
    def toggle_panel
      if DialogManager.open?
        DialogManager.close
      else
        open_panel
      end
    end
  end

  unless file_loaded?(__FILE__)
    LegacyNames.install # (what was made under the old name of the extension is brought over, before anything reads it)
    SelectionManager.install
    SnapManager.install
    RoomShell.install
    menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    menu.add_item('Open Control Panel') { EasyCabinet.open_panel }
    menu.add_item('Open or Close Room Doors and Windows') { RoomShell.open_or_close }
    menu.add_item('Create LayOut Scenes (Plan and Elevations)') { LayoutScenes.create }
    snap_item = menu.add_item('Snap Moved Cabinets to Neighbours and Walls') { SnapManager.enabled = !SnapManager.enabled? }
    menu.set_validation_proc(snap_item) { SnapManager.enabled? ? MF_CHECKED : MF_UNCHECKED }

    icons = File.join(PLUGIN_DIR, 'icons')
    open_cmd = UI::Command.new('Easy Cabinet') { EasyCabinet.toggle_panel }
    open_cmd.tooltip = 'Easy Cabinet'
    open_cmd.status_bar_text = 'Open the Easy Cabinet control panel (click again to close it)'
    open_cmd.small_icon = File.join(icons, 'icon_24.png')
    open_cmd.large_icon = File.join(icons, 'icon_32.png')
    toolbar = UI::Toolbar.new(EXTENSION_NAME)
    toolbar.add_item(open_cmd)
    toolbar.show
    file_loaded(__FILE__)
  end
end