# frozen_string_literal: true

require 'sketchup.rb'
require 'json'

module EasyCabinet
  PLUGIN_DIR = File.dirname(__FILE__).freeze unless const_defined?(:PLUGIN_DIR)
  DATA_DIR   = File.join(PLUGIN_DIR, 'data').freeze unless const_defined?(:DATA_DIR)
  HTML_DIR   = File.join(PLUGIN_DIR, 'html').freeze unless const_defined?(:HTML_DIR)
  LOADER     = File.join(File.dirname(PLUGIN_DIR), 'easy_cabinet.rb').freeze unless const_defined?(:LOADER)

  # Load order matters: Response/Defaults first, UI layer last. Loaded with Sketchup.require, so the files can be encrypted and signed for the Extension Warehouse;
  # a new version installed over a running one is loaded again with `load` (see reload_if_updated), which only works on plain .rb files.
  remove_const(:CODE_FILES) if const_defined?(:CODE_FILES)
  CODE_FILES = %w[
    response defaults model_script gola_profile attribute_manager legacy_names validation_manager material_manager catalog_manager my_appliances
    cabinet_layout appliance_parts fixtures customizer toe_kick part_layout door_animation drawer_animation handle_manager
    front_design panel_generator cabinet_generator part_generator selection_manager snap_manager
    naming_manager placement_manager tag_manager custom_door cabinet_manager part_manager worktop_manager wall_bottom_manager kitchen_planner side_exposure dimensioning dimension_manager live_parts island_hood island_back_panel kitchen_manager path_kitchen place_tool feedback_manager layout_scenes room_shell cut_list_manager preset_manager customize_manager cabinet_gallery support_status dialog_manager
  ].freeze

  def self.load_code
    CODE_FILES.each do |file|
      if @reloading then load File.join(PLUGIN_DIR, "#{file}.rb") else Sketchup.require("easy_cabinet/#{file}") end
    end
  end

  load_code
  @code_version = EXTENSION_VERSION

  class << self
    attr_reader :code_version

    # The version written in the extension file on disk right now.
    def disk_version
      File.read(LOADER, encoding: 'UTF-8')[/EXTENSION_VERSION\s*=\s*'([^']+)'/, 1]
    rescue SystemCallError
      nil
    end

    # Installing a newer .rbz over a running one replaces the files on disk, but the old code is still in memory. This loads the new code in its place, and
    # reopens the panel if it was showing, so no restart is needed. Called when the panel is opened and whenever the extension file is loaded again. (A packaged,
    # encrypted copy cannot be loaded again: it asks for a restart.)
    def reload_if_updated
      version = disk_version
      return false if version.nil? || version == @code_version

      unless File.exist?(File.join(PLUGIN_DIR, 'response.rb'))
        UI.messagebox("Easy Cabinet #{version} is installed. Please restart SketchUp to use it.") unless @restart_told == version
        @restart_told = version
        return true
      end

      reopen = DialogManager.open?
      DialogManager.close
      CustomizeManager.close
      remove_const(:EXTENSION_VERSION) if const_defined?(:EXTENSION_VERSION)
      const_set(:EXTENSION_VERSION, version)
      saved = $VERBOSE
      begin
        $VERBOSE = nil # (constants set again are not worth a warning)
        @reloading = true
        load File.join(PLUGIN_DIR, 'main.rb') # (it lists every code file: a new version may list more, and it records the new version)
      ensure
        @reloading = false
        $VERBOSE = saved
      end
      @code_version = version
      DialogManager.show if reopen
      true
    rescue StandardError, ScriptError => e
      warn "[Easy Cabinet] Could not load the new version: #{e.class}: #{e.message}"
      UI.messagebox("Easy Cabinet #{version} is installed, but could not be loaded without restarting SketchUp. Please restart SketchUp.")
      false
    end

    # What the menu item runs.
    def open_panel
      reload_if_updated
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
    SupportStatus.start # (the amount this month's support has reached is read in the background)
    LegacyNames.install # (what was made under the old name of the extension is brought over, before anything reads it)
    SelectionManager.install
    SnapManager.install
    RoomShell.install
    menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    menu.add_item('Open Control Panel') { EasyCabinet.open_panel }
    menu.add_item('Open or Close Room Doors and Windows') { RoomShell.open_or_close if SupportStatus.working? }
    menu.add_item('Create LayOut Scenes (Plan and Elevations)') { LayoutScenes.create if SupportStatus.working? }
    snap_item = menu.add_item('Snap Moved Cabinets to Neighbours and Walls') { SnapManager.enabled = !SnapManager.enabled? if SupportStatus.working? }
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