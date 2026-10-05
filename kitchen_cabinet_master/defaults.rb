# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Central place for default values. All lengths are millimetres; angles are degrees.
  module Defaults
    # Toe-kick material choices that follow another part instead of naming a material.
    CORNER_STYLES = %w[diagonal l_shape blind].freeze
    APPLIANCE_SETS = %w[oven double_oven oven_micro].freeze # what an oven housing can hold
    OVEN_HEIGHT = 595.0   # a standard built-in oven
    MICRO_HEIGHT = 380.0  # a standard built-in microwave
    DRAWER_SLIDE_GAP = 13.0     # a drawer's inner box sits this far clear of the carcass on each side
    DRAWER_BACK_GAP = 46.0      # and its back is this far from the wall behind the cabinet
    DRAWER_BOTTOM_LIFT = 10.0   # the bottom board of a drawer box is raised this far (the front and back boards start above it)
    LOWER_MODES = %w[drawers door drawer_door].freeze # the lower part of an oven housing
    SAME_AS_DOOR    = '__door__'
    SAME_AS_CARCASS = '__carcass__'
    SAME_AS_CABINET = '__cabinet__' # stored by older versions; it means "same as door material"

    CATEGORIES = [
      { 'id' => 'base', 'name' => 'Base Unit' },
      { 'id' => 'wall', 'name' => 'Wall Unit' },
      { 'id' => 'tall', 'name' => 'Tall Unit' },
      { 'id' => 'corner', 'name' => 'Corner Unit' }
    ].freeze

    # Cabinet widths offered in the "Standard Width" list (mm). Picking one fills
    # the Width field, which stays editable for any other size.
    STANDARD_WIDTHS = [300, 350, 400, 450, 500, 600, 700, 800, 900, 1000, 1200].freeze

    DIRECTIONS = [
      { 'id' => 'left',  'name' => 'Left' },
      { 'id' => 'right', 'name' => 'Right' }
    ].freeze

    # The plain white a cabinet, filler, end panel or toe kick gets when no
    # material has been chosen (a preset in data/materials.json, created on first use).
    DEFAULT_MATERIAL = 'Shutter - Light Beige'          # the doors start light beige (the L-corner builder script's shutter colour)
    DEFAULT_CARCASS_MATERIAL = 'Carcass - Light Gray'   # and the carcass light grey

    # Cabinet names are the unit code plus the width: BU600, WU800, TU600 ...
    # A catalog cabinet can set its own "code"; otherwise its category decides.
    NAME_PREFIXES = { 'base' => 'BU', 'wall' => 'WU', 'tall' => 'TU', 'corner' => 'CR', 'filler' => 'FIL',
                      'end_panel' => 'EP', 'toe_kick' => 'TK' }.freeze

    # Standalone parts: not full cabinets (see PartLayout, PartGenerator, PartManager).
    # Fillers and end panels take up their own footprint in the model; a toe kick
    # stands under the cabinets' fronts and never blocks anything.
    PART_KINDS = %w[filler end_panel toe_kick].freeze
    END_PANEL_SIDES = %w[left right].freeze


    # ---- handles ----------------------------------------------------------------
    # A bundle file (data/handles/*.json) names a profile and lists the lengths and
    # finishes it offers. "length" is the bar length, or the diameter of a knob.
    HANDLE_PROFILES = %w[bar knob].freeze

    HANDLE_ORIENTATIONS = [
      { 'id' => 'vertical',   'name' => 'Vertical' },
      { 'id' => 'horizontal', 'name' => 'Horizontal' }
    ].freeze

    # By unit type puts the handle where it is reached: near the top of a base unit's
    # door, near the bottom of a wall unit's, and at hand height on a tall unit's.
    # Top / Center / Bottom sit on the free-edge side of a hinged door; Left / Right
    # sit on that side edge, vertically centred; Custom uses exact coordinates.
    HANDLE_POSITIONS = [
      { 'id' => 'auto', 'name' => 'By unit type' }
    ].freeze

    # Positions older versions offered. They are no longer in the list, but a cabinet
    # that still has one keeps working (it moves to By unit type when next updated).
    LEGACY_HANDLE_POSITIONS = %w[top center bottom left right custom].freeze

    # Where a HORIZONTAL handle sits: at the edge of the door (where By unit type puts
    # it) or centred across the door, still at the top.
    HANDLE_HORIZONTAL_PLACES = [
      { 'id' => 'edge',   'name' => 'Doors edge' },
      { 'id' => 'middle', 'name' => 'Doors middle' }
    ].freeze

    # Used when a bundle does not say otherwise. Offsets are the clear distance (mm)
    # from the door edge to the nearest edge of the handle.
    HANDLE_DEFAULTS = {
      'orientation'     => 'horizontal',
      'position'        => 'auto', # base: top, wall: bottom, tall: at hand height
      'horizontal_place' => 'middle',
      'side_offset'     => 25.0,
      'vertical_offset' => 25.0,
      'custom_x'        => 50.0, # from the door's left edge to the handle centre
      'custom_z'        => 100.0 # from the door's bottom edge to the handle centre
    }.freeze
    TALL_HANDLE_HEIGHT = 1050.0 # a tall unit's handle is centred this high above the floor (mm)
    HANDLE_SECTION = 10.0    # bar cross-section
    HANDLE_PROJECTION = 30.0 # distance from the door face to the outer face of the grip

    # Component definitions this extension creates are named after what they are
    # (BU600, BU600 Carcass, Panel 18 x 560 x 780 ...) and carry a "managed" marker
    # attribute so they can be recognised and cleaned up. Older versions instead
    # prefixed the name with "KCM "; those are still recognised.
    LEGACY_DEFINITION_PREFIX = 'KCM '

    # Carcass construction rules (mm). Not user parameters; a future catalog
    # could override them per cabinet type.
    BACK_RECESS          = 10.0  # back panel is set this far in from the rear edge of the sides
    BACK_GROOVE          = 9.0   # a set-in back panel reaches this far into a groove in each side panel
    FLUSH_BACK_FROM      = 18.0  # ...unless it is this thick or more: then it sits flush with the sides' rear edge

    # How far in from the rear edge of the side panels the back panel sits: BACK_RECESS,
    # or nothing for a thick (18 mm) back, whose rear face is then level with the sides.
    def self.back_recess(back_thickness)
      back_thickness.to_f >= FLUSH_BACK_FROM ? 0.0 : BACK_RECESS
    end
    # The shape of a corner-type cabinet: diagonal, l_shape or blind; nil for an ordinary one. A
    # cabinet saved as category "corner" before shapes existed is a diagonal corner.
    def self.corner_style(params)
      style = params['corner_style'].to_s
      style = 'diagonal' if style.empty? && params['cabinet_category'].to_s == 'corner'
      CORNER_STYLES.include?(style) ? style : nil
    end

    # A square footprint (Width x Width) that turns the row a quarter turn.
    def self.corner?(params)
      %w[diagonal l_shape].include?(corner_style(params))
    end

    RAIL_DEPTH           = 100.0 # depth of the two structural rails that top a base unit
    SHELF_FRONT_SETBACK  = 20.0  # shelves stop this far short of the carcass front
    SHELF_SIDE_CLEARANCE = 1.0   # gap each side of a shelf so it can be removed
    TOE_KICK_RECESS      = 50.0  # the toe kick is set back this far from the carcass front
    DOOR_CLEARANCE       = 2.0   # doors stand this far in front of the carcass (the default Door Distance)
    TOP_PANEL_STYLES     = ['', 'rails', 'full'].freeze

    PARAMS = {
      'catalog_id'             => '',
      'cabinet_category'       => 'base',
      'cabinet_type'           => '',
      'handle_id'              => '',
      # Blank = use the bundle's own default. The numeric handle values
      # (length, offsets, custom position) only appear once they are set.
      'handle_finish'          => '',
      'handle_material'        => '', # blank = the material of the chosen finish
      'handle_orientation'     => '',
      'handle_position'        => '',

      'base_material'          => DEFAULT_MATERIAL,
      'wall_material'          => DEFAULT_MATERIAL,
      'tall_material'          => DEFAULT_MATERIAL,
      'cabinet_material'       => '',
      'carcass_material'       => DEFAULT_CARCASS_MATERIAL, # blank = the carcass follows the door material; it starts light grey
      'material_thickness'     => 18.0,
      'back_thickness'         => 6.0,

      'door_opening_direction' => 'left',
      'door_opening_angle'     => 90.0,
      'show_opening_direction' => false, # the plan symbol on the floor (ticked by the user when wanted)
      'corner_style' => '',        # a corner unit's shape: diagonal, l_shape or blind (blank = an ordinary cabinet)
      'door_stacked' => false,        # two doors one above the other (a built-in fridge-freezer); front_zone is the top door's height
      'front_zone' => 0.0,          # drawers over a door: the height of the drawer zone at the top; a door alone: the door's height at the top (0 = full height)
      'bottom_zone' => 0.0,         # an oven housing: the height of the drawers at the bottom (the door is front_zone at the top, the niche between)
      'appliance_set' => '',       # an oven housing: oven, double_oven or oven_micro
      'oven_height' => 595.0,
      'oven2_height' => 595.0,      # a second oven (two ovens): its own height
      'micro_height' => 380.0,
      'door_split' => false,        # a tall unit: two doors one above the other (split_height = the lower door's height)
      'split_height' => 0.0,
      'drawer_heights' => '',       # the height of each drawer front, listed from the top down; a blank one takes its share, e.g. 200,,
      'sink' => false,              # a sink in the cabinet (and its opening in the worktop)
      'sink_bowls' => 1,
      'sink_tray' => false,         # with a drainer
      'sink_mirror' => false,       # the drainer on the other side (the sink is mirrored, not turned)
      'hob' => false,               # a built-in hob on the cabinet (and its opening in the worktop)
      'hood' => false,              # a hood under a wall cabinet
      'worktop_rise' => 20.0,       # how far the worktop top stands over the carcass (what a sink or hob sits on)
      'custom_overrides' => {},     # changes made in the Customize window: part key => { extent, move } (see Customizer)
      'fridge_lift' => true,        # a built-in fridge: a lift-up door over the fridge doors (off: the top door carries on to the top)
      'free_housing' => false,      # a housing for a freestanding fridge: two side panels and a lift-up cabinet over the fridge
      'housing_lift' => 0.0,        # the height of that cabinet (0 = the standard)
      'freestanding' => false,      # a freestanding fridge: just the appliance, no carcass
      'lower_mode' => '',           # an oven housing's lower part: drawers, door or drawer_door (a small drawer over a door); '' = by the catalog
      'lower_drawers' => 2,
      'small_drawer' => 180.0,
      'fridge' => false,            # a built-in fridge: drawn behind the doors, with a lift-up door over it
      'fridge_height' => 0.0,       # the height of the fridge doors from the carcass bottom (0 = the whole unit)
      'top_front' => 0.0,           # a fixed front panel across the top (over a built-in oven): its height (0 = none)
      'drawer_pattern' => '',       # drawer fronts of unequal height, listed from the top down: "1,1,2"
      'leg2_length' => 0.0,         # an L-shaped corner: the second leg's length and depth (0 = the same as the first)
      'leg2_depth' => 0.0,
      'blind_width' => 0.0,          # a blind corner: how much of the width is the blind (closed) part
      'show_cabinet_names' => false, # the name flat on the cabinet top (a tick in Visibility)
      'hide_tall_handles' => false, # tall units' handles hidden (a tick in Visibility)
      'hide_base_handles' => false, # base units' handles hidden (a tick in Visibility)
      'hide_wall_handles' => false, # wall units' handles hidden (a tick in Visibility)
      'show_wall_opening_direction' => false, # a wall unit's plan line on the floor has its own tick
      'show_door_symbol'       => false, # the dashed swing lines on the door (ticked by the user when wanted)
      'door_gap'               => 1.5,
      'door_reveal'            => 2.0,
      'door_distance'          => DOOR_CLEARANCE, # how far the doors stand in front of the carcass
      # The top of a BASE unit: '' = two separate 10 cm panels (one full panel on an open
      # unit), 'rails' = the same, spelled out, 'full' = one full panel. Wall and tall
      # units always have one full panel.
      'top_panel_style'        => '',

      'placement_gap'          => 0.0,
      'shelf_count'            => 1,
      'carcass_raise'          => 0.0, # wall units: how far the carcass bottom is lifted (the doors stay full height)

      'toe_kick_height'        => 100.0,
      'toe_kick_thickness'     => 18.0,
      'toe_kick_material'      => SAME_AS_DOOR,
      'toe_kick_piece_length'  => 2000.0,

      'visibility_settings'    => { 'carcass' => true, 'door' => true, 'toe_kick' => true, 'appliances' => false, 'oven' => true, 'microwave' => true, 'sink' => true, 'hob' => true, 'hood' => true, 'free_fridge' => true }
    }.freeze

    # A filler: a flat board beside a cabinet, on its wall side, with its front face
    # flush with the door. `width` is how wide the gap it fills is, `thickness` how
    # thick the board is (front to back). Its height and how far it stands off the
    # floor follow the cabinet it is inserted against (the height field only
    # starts out as that cabinet's height). It has no material of its own: it
    # always takes the door material of that cabinet.
    FILLER_PARAMS = {
      'width'     => 50.0,
      'thickness' => 18.0,
      'height'    => 780.0
    }.freeze

    # A toe kick: a run of `toe_kick_pieces` pieces, each `toe_kick_piece_length`
    # long, laid end to end. `toe_kick_recess` is how far its front is set back
    # from the carcass front.
    TOE_KICK_PARAMS = {
      'toe_kick_height'       => 100.0,
      'toe_kick_thickness'    => 18.0,
      'toe_kick_material'     => SAME_AS_DOOR,
      'toe_kick_piece_length' => 2000.0,
      'toe_kick_pieces'       => 1,
      'toe_kick_cover_row'    => false,
      'toe_kick_recess'       => TOE_KICK_RECESS
    }.freeze
    DEFAULT_TOE_KICK_DEPTH = 560.0 # carcass depth assumed when no cabinet is selected

    # An end panel: which side of the currently selected cabinet/filler it goes
    # on, and its own depth (front to back), thickness (its width in the front
    # view) and height (floor to top). Depth starts as the target's door front, so
    # the panel is flush with the doors, and height as the target's top; the
    # numbers here are only what the panel shows before anything is selected. The
    # material starts as "same as door material" and follows the door until one is
    # picked by hand.
    END_PANEL_PARAMS = {
      'side'      => 'right',
      'depth'     => 580.0,
      'thickness' => 18.0,
      'height'    => 880.0,
      'material'  => SAME_AS_DOOR
    }.freeze

    # Returns a deep, mutable copy so callers can modify it freely.
    def self.params
      JSON.parse(JSON.generate(PARAMS))
    end

    def self.filler_params
      JSON.parse(JSON.generate(FILLER_PARAMS))
    end

    def self.end_panel_params
      JSON.parse(JSON.generate(END_PANEL_PARAMS))
    end

    def self.toe_kick_params
      JSON.parse(JSON.generate(TOE_KICK_PARAMS))
    end

    def self.category_ids
      CATEGORIES.map { |c| c['id'] }
    end

    def self.direction_ids
      DIRECTIONS.map { |d| d['id'] }
    end

    def self.handle_orientation_ids
      HANDLE_ORIENTATIONS.map { |o| o['id'] }
    end

    def self.handle_position_ids
      HANDLE_POSITIONS.map { |o| o['id'] } + LEGACY_HANDLE_POSITIONS
    end

    def self.handle_horizontal_place_ids
      HANDLE_HORIZONTAL_PLACES.map { |o| o['id'] }
    end
  end
end
