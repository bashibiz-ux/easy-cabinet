(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);

  // What the panel remembered under the old name of the extension (the unit, the language, the order of the cards ...) is kept under the new one.
  try {
    ['unit', 'lang', 'cardOrder', 'followSelection'].forEach((key) => {
      const old = localStorage.getItem(`kcm.${key}`);
      if (old !== null && localStorage.getItem(`ec.${key}`) === null) localStorage.setItem(`ec.${key}`, old);
    });
  } catch (_) { /* a private window: nothing to bring over */ }

  // Must match EXTENSION_VERSION in easy_cabinet.rb. If SketchUp is still
  // running older Ruby files than this panel (an update without a restart), the
  // panel says so instead of failing on data the old Ruby never sends.
  const APP_VERSION = '1.114.1';

  const list = (value) => (Array.isArray(value) ? value : []);

  const FALLBACK_LISTS = {
    handle_orientations: [{ id: 'vertical', name: 'Vertical' }, { id: 'horizontal', name: 'Horizontal' }],
    handle_positions: [{ id: 'auto', name: 'By unit type' }],
    handle_horizontal_places: [{ id: 'edge', name: 'Doors edge' }, { id: 'middle', name: 'Doors middle' }],
    end_panel_sides: [{ id: 'left', name: 'Left' }, { id: 'right', name: 'Right' }]
  };

  const FILLER_FIELD_TO_ELEMENT = {
    width: 'fillerWidth', thickness: 'fillerThickness', height: 'fillerHeight'
  };
  const END_PANEL_FIELD_TO_ELEMENT = { side: 'epSide', depth: 'epDepth', thickness: 'epThickness', height: 'epHeight', material: 'epMaterial' };

  // Server field name -> id of the element that edits it (used to highlight errors).
  const FIELD_TO_ELEMENT = {
    catalog_id: 'catalog',
    handle_id: 'handle',
    handle_material: 'handleMaterial',
    base_material: 'baseMaterial',
    wall_material: 'wallMaterial',
    tall_material: 'tallMaterial',
    material_thickness: 'thickness',
    back_thickness: 'backThickness',
    door_gap: 'doorGap',
    door_distance: 'doorDistance',
    front_radius: 'frontRadius',
    top_panel_style: 'topPanel',
    door_opening_direction: 'direction',
    door_opening_angle: 'angle',
    symbol_angle: 'symbolAngle',
    cabinet_category: 'category',
    cabinet_type: 'cabinet',
    placement_gap: 'gap',
    width: 'width',
    depth: 'depth',
    height: 'height',
    carcass_raise: 'carcassRaise',
    door_height_adjust: 'doorHeightAdjust',
    drawer_height_adjust: 'drawerHeightAdjust',
    leg2_length: 'leg2Length',
    leg2_depth: 'leg2Depth',
    appliance_set: 'applianceSet',
    front_zone: 'zoneHeight',
    oven_height: 'ovenHeight',
    oven2_height: 'ovenHeight2',
    bottom_zone: 'bottomHeight',
    top_front: 'topFrontHeight',
    fridge_height: 'fridgeHeight',
    blind_width: 'blindWidth',
    dividers: 'dividers',
    split_height: 'splitHeight',
    housing_lift: 'liftHeight',
    finger_gap: 'fingerGapGlobal',
    finger_gap_drawer: 'fingerGapGlobal',
    drawer_heights: 'drawerH1',
    sink_bowls: 'sinkBowls',
    lower_mode: 'lowerMode',
    lower_drawers: 'lowerDrawers',
    small_drawer: 'smallDrawer',
    micro_height: 'microHeight',
    wall_bottom_thickness: 'wbThickness',
    wall_bottom_length: 'wbLength',
    wall_bottom_setback: 'wbSetback',
    wall_bottom_loft_setback: 'wbLoftSetback',
    shelf_count: 'shelves',
    carcass_material: 'carcassMaterial',
    door_reveal: 'doorReveal',
    toe_kick_height: 'toeHeight',
    toe_kick_thickness: 'toeThickness',
    toe_kick_material: 'toeMaterial',
    toe_kick_piece_length: 'pieceLength',
    toe_kick_pieces: 'pieceCount',
    toe_kick_recess: 'toeRecess',
    handle_length: 'handleLength',
    handle_finish: 'handleFinish',
    handle_material: 'handleMaterial',
    handle_orientation: 'handleOrientation',
    handle_position: 'handlePosition',
    handle_horizontal_place: 'handleHPlace',
    handle_side_offset: 'handleSide',
    handle_vertical_offset: 'handleVert',
    handle_custom_x: 'handleCustomX',
    handle_custom_z: 'handleCustomZ'
  };

  // Server parameter -> element id, for filling the form from stored parameters.
  const TEXT_PARAMS = {
    material_thickness: 'thickness',
    back_thickness: 'backThickness',
    door_gap: 'doorGap',
    door_reveal: 'doorReveal',
    door_distance: 'doorDistance',
    front_radius: 'frontRadius',
    carcass_raise: 'carcassRaise',
    door_height_adjust: 'doorHeightAdjust',
    drawer_height_adjust: 'drawerHeightAdjust',
    door_opening_angle: 'angle',
    symbol_angle: 'symbolAngle',
    placement_gap: 'gap',
    width: 'width',
    depth: 'depth',
    height: 'height',
    shelf_count: 'shelves',
    toe_kick_height: 'toeHeight',
    toe_kick_thickness: 'toeThickness',
    toe_kick_piece_length: 'pieceLength',
    toe_kick_pieces: 'pieceCount',
    toe_kick_recess: 'toeRecess',
    handle_side_offset: 'handleSide',
    handle_vertical_offset: 'handleVert',
    handle_custom_x: 'handleCustomX',
    handle_custom_z: 'handleCustomZ'
  };

  const SELECT_PARAMS = {
    handle_id: 'handle',
    base_material: 'baseMaterial',
    wall_material: 'wallMaterial',
    tall_material: 'tallMaterial',
    carcass_material: 'carcassMaterial',
    top_panel_style: 'topPanel',
    toe_kick_material: 'toeMaterial',
    door_opening_direction: 'direction',
    handle_length: 'handleLength',
    handle_finish: 'handleFinish',
    handle_orientation: 'handleOrientation',
    handle_position: 'handlePosition',
    handle_horizontal_place: 'handleHPlace'
  };

  const REQUEST_TIMEOUT_MS = 20000;

  const state = {
    meta: null,
    cabinets: [],
    colors: {},
    finishColors: {},
    pending: new Map(),
    seq: 0,
    busy: false,
    lastMaterialRefresh: 0,
    // What is selected in the model: 'cabinet', 'filler', 'end_panel', 'toe_kick' or null.
    selectedKind: null,
    wallBottomSelected: false, // a wall bottom panel is selected: its settings are for it alone
    // Filler / side panel fields the user has set themselves (see followCabinet).
    touched: new Set(),
    unit: 'mm',
    animate: false // section animations start once the panel is built
  };

  /* ---------------------------------------------------------------------- *
   * Bridge to Ruby
   * ---------------------------------------------------------------------- */

  function call(action, data = {}) {
    if (/^(set_live_|visibility$|set_snap$|set_unit_sizes$|reset_unit_sizes$)/.test(action)) state.noFocusUntil = Date.now() + 4000; // (a switch of the Settings: the item it re-selects does not open Cabinets and Extras)
    return new Promise((resolve, reject) => {
      if (!window.sketchup || typeof window.sketchup.ec_request !== 'function') {
        reject(new Error('Not connected to SketchUp. Open this panel from Extensions > Easy Cabinet.'));
        return;
      }
      const id = ++state.seq;
      const timer = setTimeout(() => {
        state.pending.delete(id);
        reject(new Error('SketchUp did not answer in time.'));
      }, REQUEST_TIMEOUT_MS);
      state.pending.set(id, { resolve, timer });
      window.sketchup.ec_request(JSON.stringify({ id, action, data }));
    });
  }

  // Called by Ruby via dialog.execute_script.
  window.EC = {
    receive(message) {
      if (!message) return;
      if (message.id !== undefined && message.id !== null && state.pending.has(message.id)) {
        const entry = state.pending.get(message.id);
        state.pending.delete(message.id);
        clearTimeout(entry.timer);
        entry.resolve(message);
      } else if (message.event) {
        handleEvent(message.event, message.data || {});
      }
    }
  };

  // What the user has selected in the model decides which form Update reads and
  // what Update / Delete act on: a cabinet, a filler, an side panel or a toe kick.
  function handleEvent(name, data) {
    // The tool sends 'info' (placed) or 'notice' (not placed) right after the click, and place_end when it is put away: whichever comes, the card is not marked any more.
    if (gallery.picked && (name === 'info' || name === 'notice' || name === 'place_end')) clearPicked();
    if (name === 'place_end') { // the placing is over (the cabinet was put down, or Esc): its card is not marked any more, and
      clearPicked();
      //  the late selection events of the insert are still left alone, then what is selected is read once
      state.noFocusUntil = Date.now() + 1500;
      setTimeout(() => { call('get_selection').catch(() => {}); }, 1700);
      return;
    }
    if (followSelection() || name === 'cabinet_cleared') { state.heldKind = null; state.heldData = null; }
    // With the tick off, picking something in the model does not open its settings: the panel stays as it is. A cabinet that is selected is
    // remembered, so that a field edited in the panel changes that cabinet alone (see scheduleHeld).
    // With the tick off nothing is opened or scrolled to, but a card that is already open (Presets, Handle, Material or Cabinet & Extras) still shows what is selected.
    const quiet = !followSelection();
    // (a card that shows the settings of what is selected: Presets, Handle, Material, Cabinet & Extras)
    const hosting = ['sec-presets', 'sec-handle', 'sec-material', 'sec-cabinet'].some((id) => $(id) && !$(id).classList.contains('collapsed'));
    const inOpenCard = quiet && hosting && (name === 'cabinet_selected' || (name === 'part_selected' && !['worktop', 'backsplash'].includes(data.part_kind)));
    if (quiet && (name === 'cabinet_selected' || name === 'part_selected') && !inOpenCard) {
      state.selectedKind = null;
      state.wallBottomSelected = false;
      state.heldKind = name === 'cabinet_selected' ? 'cabinet' : null;
      state.heldData = name === 'cabinet_selected' ? data : null; // (shown as soon as a card that can show it is opened, see showHeld)
      setBadge(null);
      return;
    }
    if (inOpenCard) state.heldKind = null;
    // Our own live update re-selects the item it just changed; do not let that
    // overwrite what the user is in the middle of typing.
    // (and the selection that is cleared for a moment while it is drawn again must not make the panel forget it: Ruby selects it again)
    if (state.liveBusy && (name === 'cabinet_selected' || name === 'part_selected' || name === 'cabinet_cleared')) {
      // (only the name at the top is brought up to date: a changed size can change the name)
      if (name === 'cabinet_selected') setBadge(data.cabinet_name || data.cabinet_id || null);
      else if (name === 'part_selected') setBadge(data.part_name || null);
      return;
    }

    // (a switch of the Settings has just redrawn parts and selected again what was selected: that is no click in the model, so the Category and the cards stay as they are)
    if (Date.now() < (state.noFocusUntil || 0) && (name === 'cabinet_selected' || name === 'part_selected')) {
      setBadge(name === 'cabinet_selected' ? (data.cabinet_name || data.cabinet_id || null) : (data.part_name || null));
      return;
    }

    if (name === 'cabinet_selected' || name === 'part_selected' || name === 'cabinet_cleared') { state.liveHold = false; state.wallBottomSelected = false; }

    if (name === 'cabinet_selected') {
      state.selectedKind = 'cabinet';
      loadCabinet(data);
      if (!quiet) focusSection('sec-cabinet', data.cabinet_id);
    } else if (name === 'part_selected') {
      // A worktop has its own section: show its values there and leave the item list alone.
      if (data.part_kind === 'wall_bottom') {
        // Clicking a wall bottom panel opens the Wall Bottom Panel section with its values.
        state.selectedKind = null;
        state.wallBottomSelected = true;
        setBadge(data.part_name);
        if (data.wall_bottom_thickness) setText('wbThickness', data.wall_bottom_thickness);
        if (data.wall_bottom_length !== undefined) setText('wbLength', data.wall_bottom_length);
        if (data.wall_bottom_setback !== undefined) setText('wbSetback', data.wall_bottom_setback);
        if (data.wall_bottom_loft_setback !== undefined) setText('wbLoftSetback', data.wall_bottom_loft_setback);
        if (data.material) setSelect('wbMaterial', data.material);
        updateChips();
        setSelect('category', 'wall_bottom'); // (it is a Category of the Cabinet & Extras section)
        updateCategoryUi();
        if (!quiet) focusSection('sec-cabinet', data.part_id || data.part_name);
        return;
      }
      if (data.part_kind === 'worktop' || data.part_kind === 'backsplash') {
        state.selectedKind = 'worktop';
        setBadge(data.part_name);
        applyWorktopDefaults(data);
        focusSection('sec-worktop', data.part_id || data.part_name);
        return;
      }
      const kind = data.ceiling_filler ? 'ceiling_filler' : (['end_panel', 'toe_kick', 'panel'].includes(data.part_kind) ? data.part_kind : 'filler');
      state.selectedKind = kind;
      // A part is edited with the Cabinet & Extras fields, which need a catalog: use the first if none is chosen.
      if (!$('catalog').value && list(state.meta.catalogs)[0]) {
        setSelect('catalog', list(state.meta.catalogs)[0].id);
        applyCatalogFeatures();
      }
      setBadge(data.part_name);
      if (kind === 'end_panel') applyEndPanelDefaults(data);
      else if (kind === 'panel') applyPanelDefaults(data);
      else if (kind === 'ceiling_filler') applyCeilingFillerDefaults(data);
      else if (kind === 'toe_kick') applyToeKickDefaults(data);
      else applyFillerDefaults(data);
      // A filler is something an side panel can go on: its front and top are what that panel starts from.
      if (kind === 'filler') followCabinet({ front: data.envelope_depth, top: data.target_category === 'wall' ? data.envelope_top - data.target_base_z : data.envelope_top });
      // Filler, Side Panel and Toe Kick are Cabinet Category choices: show the matching fields.
      setSelect('category', kind);
      updateCategoryUi();
      if (!quiet) focusSection('sec-cabinet', data.part_id || data.part_name);
    } else if (name === 'cabinet_cleared') {
      state.selectedKind = null;
      state.focusKey = null;
      setBadge(null);
    } else if (name === 'splash_height') {
      if (document.activeElement !== $('wtSplash') && data.height > 0) setText('wtSplash', data.height); // (the height the back splash has now: it follows the wall units)
    } else if (name === 'info') {
      setStatus('ok', data.message || '');
    } else if (name === 'notice') {
      setStatus('error', data.message || '');
    } else if (name === 'snap') {
      // A moved cabinet was snapped to a neighbour and / or the wall (or could not be).
      setStatus('ok', data.message);
    }
  }

  // Clicking an item in the model opens the section that edits it, ready to edit (the sections are an accordion).
  // Only when it is a different item than the one already open, so editing is never interrupted.
  // The Feedback window: the message goes out from the user's own mail program (see FeedbackManager).
  // The Donate button opens the donation page (see FeedbackManager).
  // The button of the action bar that was pressed last stays orange (the others are dark brown).
  function wireActiveTile() {
    const tiles = [...document.querySelectorAll('.actions .btn.tile')].filter((tile) => tile.id !== 'openMore' && !tile.closest('.more-menu'));
    tiles.forEach((tile) => tile.addEventListener('click', () => {
      tiles.forEach((other) => other.classList.toggle('active', other === tile));
    }));
  }

  // The More tile: a small menu with Donate, Feedback and Help. It closes when something is chosen, on a click elsewhere, and with Esc.
  function wireMore() {
    const button = $('openMore');
    const menu = $('moreMenu');
    if (!button || !menu) return;
    const set = (open) => { menu.hidden = !open; button.setAttribute('aria-expanded', String(open)); button.classList.toggle('active', open); };
    button.addEventListener('click', (e) => { e.stopPropagation(); set(menu.hidden); });
    menu.addEventListener('click', () => set(false));
    document.addEventListener('click', (e) => { if (!menu.hidden && !menu.contains(e.target)) set(false); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !menu.hidden) set(false); });
    const help = $('helpModal');
    const closeHelp = () => { help.hidden = true; };
    $('openHelp').addEventListener('click', () => { help.hidden = false; });
    $('helpClose').addEventListener('click', closeHelp);
    help.addEventListener('click', (e) => { if (e.target === help) closeHelp(); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !help.hidden) closeHelp(); });
    $('helpOnline').addEventListener('click', async () => {
      try {
        const res = await call('open_help', {});
        setStatus(res.ok ? 'ok' : 'error', res.message);
      } catch (error) {
        setStatus('error', error.message);
      }
    });
    $('helpFeedback').addEventListener('click', () => { closeHelp(); $('openFeedback').click(); });
  }

  // The News and Forum windows of the More menu: a list read from the web when the window opens. A click on an entry (or Start a conversation, or a reply) asks
  // first, as the page is on another site and may need an account, then opens it in the browser.
  // The post of a news item is written as HTML on the web: only plain formatting is kept (paragraphs, headings, lists, bold, italic, links, pictures from https)
  // and everything else (scripts, frames, styles, handlers) is dropped. A link opens in the browser through Ruby.
  const NEWS_TAGS = new Set(['P', 'BR', 'STRONG', 'B', 'EM', 'I', 'U', 'A', 'UL', 'OL', 'LI', 'H1', 'H2', 'H3', 'H4', 'IMG', 'BLOCKQUOTE', 'CODE', 'PRE', 'HR', 'SPAN', 'DIV']);
  const NEWS_DROP = new Set(['SCRIPT', 'STYLE', 'IFRAME', 'OBJECT', 'EMBED', 'LINK', 'META', 'FORM', 'INPUT', 'BUTTON', 'SVG', 'VIDEO', 'AUDIO', 'TEXTAREA', 'SELECT']);
  function cleanNews(html, openLink) {
    const doc = new DOMParser().parseFromString(String(html || ''), 'text/html');
    const build = (parent, out) => {
      parent.childNodes.forEach((node) => {
        if (node.nodeType === 3) { out.append(document.createTextNode(node.textContent)); return; }
        if (node.nodeType !== 1 || NEWS_DROP.has(node.tagName)) return;
        if (!NEWS_TAGS.has(node.tagName)) { build(node, out); return; } // (an unknown tag: its content stays, the tag goes)
        const tag = node.tagName === 'H1' ? 'h2' : node.tagName.toLowerCase();
        const el = document.createElement(tag);
        if (tag === 'a') {
          const href = node.getAttribute('href') || '';
          if (/^https:\/\//i.test(href)) { el.href = '#'; el.addEventListener('click', (e) => { e.preventDefault(); openLink(href); }); }
        } else if (tag === 'img') {
          const src = node.getAttribute('src') || '';
          if (!/^https:\/\//i.test(src)) return;
          el.src = src;
          el.alt = node.getAttribute('alt') || '';
          el.loading = 'lazy';
        }
        build(node, el);
        out.append(el);
      });
    };
    const box = document.createDocumentFragment();
    build(doc.body, box);
    return box;
  }

  function wireCommunity() {
    const modal = $('communityModal');
    if (!modal || !$('openNews')) return;
    const list = $('communityList');
    let pending = '';
    const text = (tag, className, value) => { const el = document.createElement(tag); el.className = className; el.textContent = value; return el; };
    const close = () => { modal.hidden = true; pending = ''; };
    const showList = (show) => { $('communityNote').hidden = show; $('communityRedirect').hidden = show; $('communityButtons').hidden = !show; list.hidden = !show; };
    const ask = (url) => { if (!url) return; pending = url; showList(false); };
    const empty = (message) => { list.replaceChildren(text('div', 'community-empty', message)); };
    const openLink = (url) => call('open_link', { url }).then((r) => { if (!r.ok) setStatus('error', r.message); }).catch(() => {});
    // A post of the news or of the forum: who wrote it and when, then the post itself, and a link to its page (Comment on the news, Reply in the forum).
    const newsPost = (entry, kind = 'news') => {
      const post = document.createElement('article');
      post.className = 'news-post';
      const head = document.createElement('div');
      head.className = 'news-head';
      if (entry.avatar) { const pic = document.createElement('img'); pic.className = 'news-avatar'; pic.src = entry.avatar; pic.alt = ''; head.append(pic); }
      const about = document.createElement('div');
      about.append(text('div', 'news-title', entry.title));
      const meta = text('div', 'news-meta', '');
      if (entry.author) meta.append(text('span', 'news-author', entry.author));
      if (entry.date) meta.append(document.createTextNode(entry.date));
      if (kind === 'forum' && entry.replies) meta.append(document.createTextNode(` · ${entry.replies} ${entry.replies === 1 ? 'reply' : 'replies'}`));
      about.append(meta);
      head.append(about);
      const body = document.createElement('div');
      body.className = 'news-body';
      if (entry.html) body.append(cleanNews(entry.html, openLink)); else if (entry.text) body.append(text('p', '', entry.text)); else if (entry.body) body.append(text('p', 'news-text', entry.body));
      post.append(head, body);
      if (kind === 'forum' && entry.tags && entry.tags.length) { const tags = text('div', 'news-tags', ''); entry.tags.forEach((tag) => tags.append(text('span', '', tag))); post.append(tags); }
      if (entry.url) { const more = text('a', 'news-link', kind === 'forum' ? 'Reply' : 'Comment'); more.href = '#'; more.addEventListener('click', (e) => { e.preventDefault(); if (kind === 'forum') ask(entry.url); else openLink(entry.url); }); const foot = text('div', 'news-foot', ''); foot.append(more); post.append(foot); }
      return post;
    };
    const open = async (kind) => {
      $('communityTitle').textContent = kind === 'news' ? 'News' : 'Forum';
      $('communityHelp').textContent = kind === 'news' ? 'The latest news from Easy Cabinet.' : 'This message board lets you exchange with the other users and the Easy Cabinet team.';
      $('communityNew').hidden = true; $('communityButtons').classList.add('single');
      $('communityCard').classList.add('wide'); // (the news and the forum are read like a page)
      showList(true);
      empty('Loading...');
      modal.hidden = false;
      try {
        const res = await call(kind === 'news' ? 'get_news' : 'get_forum', {});
        if (!res.ok) { empty(res.message); return; }
        const entries = kind === 'news' ? res.data.items : res.data.topics;
        if (kind === 'forum' && res.data.new_url) { $('communityNew').hidden = false; $('communityButtons').classList.remove('single'); $('communityNew').dataset.url = res.data.new_url; }
        if (!entries.length) { empty(kind === 'news' ? 'There is no news yet.' : 'There are no conversations yet.'); return; }
        list.replaceChildren(...entries.map((entry) => newsPost(entry, kind)));
      } catch (error) {
        empty(error.message);
      }
    };
    $('openNews').addEventListener('click', () => open('news'));
    $('openForum').addEventListener('click', () => open('forum'));
    $('communityClose').addEventListener('click', close);
    $('communityNew').addEventListener('click', () => ask($('communityNew').dataset.url));
    $('communityBack').addEventListener('click', () => { pending = ''; showList(true); });
    $('communityGo').addEventListener('click', async () => {
      const url = pending;
      pending = '';
      showList(true);
      try { const res = await call('open_link', { url }); setStatus(res.ok ? 'ok' : 'error', res.message); } catch (error) { setStatus('error', error.message); }
    });
    modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) close(); });
  }

  // The Donate item of the More menu opens the Support window: the goal for the next version in US dollars (the target, what was achieved, what is left),
  // read from the web when it opens. Contribute... opens the donation page.
  function wireDonate() {
    const button = $('openDonate');
    const modal = $('supportModal');
    if (!button || !modal) return;
    const usd = (value) => `$${Number(value).toLocaleString('en-US', { minimumFractionDigits: Number.isInteger(Number(value)) ? 0 : 2, maximumFractionDigits: 2 })}`;
    const close = () => { modal.hidden = true; };
    button.addEventListener('click', async () => {
      $('supportGoal').hidden = true;
      $('supportMessage').hidden = false;
      $('supportMessage').textContent = 'Loading...';
      modal.hidden = false;
      try {
        const res = await call('get_support', {});
        if (!res.ok) { $('supportMessage').textContent = res.message; return; }
        const goal = res.data;
        $('supportMessage').hidden = true;
        $('supportObjective').textContent = goal.objective || 'Objective';
        $('supportFunded').textContent = `funded at ${goal.percent}%`;
        $('supportTarget').textContent = usd(goal.target);
        $('supportTarget2').textContent = usd(goal.target);
        $('supportRaised').textContent = usd(goal.raised);
        $('supportRemaining').textContent = usd(goal.remaining);
        $('supportRaisedLabel').textContent = goal.raised > 0 ? usd(goal.raised) : '';
        $('supportFill').style.width = `${goal.percent}%`;
        $('supportPeople').textContent = goal.contributors ? `${goal.contributors} financial ${goal.contributors === 1 ? 'contributor' : 'contributors'}` : '';
        $('supportText').textContent = goal.text || '';
        $('supportText').hidden = !goal.text;
        $('supportGoal').hidden = false;
      } catch (error) {
        $('supportMessage').textContent = error.message;
      }
    });
    $('supportClose').addEventListener('click', close);
    modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) close(); });
    $('supportContribute').addEventListener('click', async () => {
      try {
        const res = await call('open_donation', {});
        setStatus(res.ok ? 'ok' : 'error', res.message);
      } catch (error) {
        setStatus('error', error.message);
      }
    });
  }

  function wireFeedback() {    const modal = $('feedbackModal');
    if (!modal) return;
    const close = () => { modal.hidden = true; };
    $('openFeedback').addEventListener('click', () => { modal.hidden = false; $('feedbackMessage').focus(); });
    $('feedbackCancel').addEventListener('click', close);
    modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) close(); });
    const payload = (via) => ({ via, kind: $('feedbackKind').value, message: $('feedbackMessage').value, reply_to: $('feedbackReply').value, include_info: $('feedbackInfo').checked });
    modal.querySelectorAll('[data-via]').forEach((button) => button.addEventListener('click', async () => {
      try {
        const res = await call('send_feedback', payload(button.dataset.via));
        setStatus(res.ok ? 'ok' : 'error', res.message);
        if (res.ok) { $('feedbackMessage').value = ''; close(); }
      } catch (error) {
        setStatus('error', error.message);
      }
    }));
    $('feedbackCopy').addEventListener('click', async () => {
      try {
        const res = await call('send_feedback', payload('text'));
        if (!res.ok) { setStatus('error', res.message); return; }
        const holder = document.createElement('textarea');
        holder.value = res.data.text;
        document.body.appendChild(holder);
        holder.select();
        let copied = false;
        try { copied = document.execCommand('copy'); } catch (_) { copied = false; }
        holder.remove();
        setStatus(copied ? 'ok' : 'error', copied ? 'Copied: paste it into a mail to the address at the top.' : `It could not be copied here. Send your message to ${res.data.text.split('\n')[0].replace('To: ', '')}.`);
      } catch (error) {
        setStatus('error', error.message);
      }
    });
  }

  function focusSection(id, key) {
    if (state.focusKey === key || Date.now() < (state.noFocusUntil || 0)) return; // (not while a switch of the Settings is working)
    state.focusKey = key;
    const card = $(id);
    if (!card) return;
    toggleCard(card, true);
    card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function applyToeKickDefaults(d) {
    setText('toeHeight', d.toe_kick_height ?? 100);
    setText('toeThickness', d.toe_kick_thickness);
    setText('pieceLength', d.toe_kick_piece_length);
    setText('pieceCount', d.toe_kick_pieces);
    $('toeCover').checked = d.toe_kick_cover_row === true;
    setText('toeRecess', d.toe_kick_recess);
    const material = d.toe_kick_material === '__cabinet__' ? '__door__' : d.toe_kick_material;
    setSelect('toeMaterial', material || '__door__');
    updateChips();
    drawPreview();
  }

  function collectToeKick() {
    return {
      toe_kick_height: mmv('toeHeight'),
      toe_kick_thickness: mmv('toeThickness'),
      toe_kick_material: $('toeMaterial').value,
      toe_kick_piece_length: mmv('pieceLength'),
      toe_kick_pieces: $('pieceCount').value,
      toe_kick_cover_row: $('toeCover').checked,
      toe_kick_recess: mmv('toeRecess'),
      // Used only when nothing is selected: the carcass depth the toe kick sits under.
      depth: mmv('depth'),
      // A new toe kick follows the Toe Kick tick in the Visibility section.
      visible: $('visToe').checked
    };
  }

  // The Panel category: a plain vertical or horizontal board.
  function collectPanel() {
    return {
      orientation: $('panelOrientation').value,
      width: mmv('panelWidth'),
      length: mmv('panelLength'),
      thickness: mmv('panelThickness'),
      material: $('panelMaterial').value,
      door_material: $('baseMaterial').value // ("same as door material" is the Base Unit's)
    };
  }

  function applyPanelDefaults(d) {
    setSelect('panelOrientation', d.orientation || 'vertical');
    setText('panelWidth', d.width);
    setText('panelLength', d.length);
    setText('panelThickness', d.thickness);
    setSelect('panelMaterial', d.material_choice || d.material || '__door__');
    syncPanelUi();
    updateChips();
    drawPreview();
  }

  // The second size of a panel is its height when it stands and its depth when it lies.
  function syncPanelUi() {
    const label = $('panelLengthLabel');
    if (label) label.textContent = $('panelOrientation').value === 'horizontal' ? 'Depth' : 'Height';
  }

  // The Ceiling Filler section: like the Toe Kick fields, what is entered is for every ceiling filler (live).
  const CEILING_FILLER_IDS = ['cfHeight', 'cfThickness', 'cfRecess', 'cfPiece', 'cfMaterial'];

  function collectCeilingFiller() {
    return { height: mmv('cfHeight'), thickness: mmv('cfThickness'), recess: mmv('cfRecess'), piece_length: mmv('cfPiece'), material: $('cfMaterial').value };
  }

  function applyCeilingFillerDefaults(d) {
    setText('cfHeight', d.height);
    setText('cfThickness', d.thickness);
    setText('cfRecess', d.ceiling_recess);
    setText('cfPiece', d.ceiling_piece_length);
    setSelect('cfMaterial', d.material_choice || '__door__');
    updateChips();
    drawPreview();
  }

  function scheduleCeilingFiller(delay) {
    clearTimeout(state.cfTimer);
    state.cfTimer = setTimeout(async () => {
      if (state.busy) { scheduleCeilingFiller(300); return; }
      state.busy = true;
      state.liveBusy = true;
      try {
        const res = await call('apply_ceiling_fillers', collectCeilingFiller());
        setStatus(res.ok ? 'ok' : 'error', res.message);
      } catch (error) {
        setStatus('error', error.message);
      } finally {
        state.busy = false;
        state.liveBusy = false;
      }
    }, delay);
  }

  function applyFillerDefaults(d) {
    setText('fillerWidth', d.width);
    setText('fillerThickness', d.thickness);
    setText('fillerHeight', d.height);
    updateChips();
    drawPreview();
  }

  // A filler's height STARTS as the height of the cabinet in the model and follows
  // it as cabinets are selected, until the user types their own. Then it stays
  // put, so "enter the data, select the cabinet, Insert" keeps what was entered.
  // (A filler's material is not a field: it always follows the door material.)
  //
  // An side panel's depth and height start the same way: depth flush with the door
  // front (`front`) and height up to the top (`top`) of what is selected.
  const FOLLOWS_CABINET = ['fillerHeight', 'epDepth', 'epHeight'];

  function followCabinet(cabinet) {
    const set = (id, value) => { if (value && !state.touched.has(id)) setText(id, value); };
    set('fillerHeight', cabinet.height);
    set('epDepth', cabinet.front);
    set('epHeight', cabinet.top);
    drawPreview();
  }

  // After a filler is inserted, the next one starts from the cabinet again.
  function resetFollowing() {
    FOLLOWS_CABINET.forEach((id) => state.touched.delete(id));
  }

  function applyEndPanelDefaults(d) {
    setSelect('epSide', d.side);
    setText('epDepth', d.depth);
    setText('epThickness', d.thickness);
    setText('epHeight', d.height);
    setSelect('epMaterial', d.material_choice || d.material || '__door__');
    setSelect('epFace', d.face || 'flat');
    updateChips();
    drawPreview();
  }

  let splashTyped = false; // the back splash height was typed: it stays, instead of following the wall units
  document.addEventListener('input', (e) => { if (e.target && e.target.id === 'wtSplash') splashTyped = true; }, true);

  function collectWorktop() {
    return {
      backsplash_auto: !splashTyped,
      worktop_thickness: mmv('wtThickness'),
      worktop_front: mmv('wtFront'),
      worktop_end: mmv('wtEnd'),
      worktop_round: mmv('wtRound'),
      worktop_piece: 0, // cutting into pieces was taken out of the panel
      worktop_cuts: '',
      backsplash_height: mmv('wtSplash'),
      material: $('wtMaterial').value,
      backsplash_material: $('wtSplashMaterial').value === '__same__' ? '' : $('wtSplashMaterial').value,
      selected_only: state.selectedKind === 'worktop' // with a worktop piece selected the settings are for its run alone
    };
  }

  // The Cut At field is a list of lengths ("1500, 3000"): each one is converted
  // between the chosen unit and mm like any other length.
  function cutsToMm() {
    return $('wtCuts').value.split(/[\s,;]+/).filter(Boolean).map((token) => {
      const n = num(token);
      return Number.isFinite(n) ? String(Math.round(n * unitInfo().mm * 1e6) / 1e6) : token;
    }).join(',');
  }

  function showCuts(mmText) {
    $('wtCuts').value = String(mmText || '').split(',').filter(Boolean).map((token) => {
      const n = num(token);
      return Number.isFinite(n) ? fmtU(n) : token;
    }).join(', ');
  }

  function applyWorktopDefaults(d) {
    setText('wtThickness', d.worktop_thickness);
    setText('wtFront', d.worktop_front);
    setText('wtEnd', d.worktop_end);
    setText('wtRound', d.worktop_round);
    setText('wtPiece', d.worktop_piece);
    setText('wtSplash', d.backsplash_height);
    splashTyped = d.backsplash_auto === false;
    showCuts(d.worktop_cuts);
    setSelect('wtMaterial', d.material);
    setSelect('wtSplashMaterial', d.backsplash_material || '__same__');
  }

  function collectFiller() {
    return {
      width: mmv('fillerWidth'),
      thickness: mmv('fillerThickness'),
      height: mmv('fillerHeight'),
      // Untouched, the height is the selected unit's own (a tall, base or wall filler).
      height_auto: !state.touched.has('fillerHeight')
    };
  }

  function collectEndPanel() {
    return {
      side: $('epSide').value,
      depth: mmv('epDepth'),
      depth_auto: !state.touched.has('epDepth'),
      thickness: mmv('epThickness'),
      height: mmv('epHeight'),
      height_auto: !state.touched.has('epHeight'),
      material: $('epMaterial').value,
      face: $('epFace').value,
      to_ceiling: $('epToCeiling').checked, // (on: beside a unit with a loft over it the panel goes on up to the ceiling)
      to_floor: $('epToFloor').checked, // (on: the end of a row goes down to the floor; off: only on the cabinet)
      front_radius: mmv('frontRadius'), // its outer edges are as round as the doors'
      front_design: $('frontDesign').value // the design an side panel set to follow the front design is cut in
    };
  }

  /* ---------------------------------------------------------------------- *
   * Saved settings: kept between sessions, restored when the panel opens
   * ---------------------------------------------------------------------- */

  const PRESET_IDS = [
    'units', 'cfHeight', 'cfThickness', 'cfRecess', 'cfPiece', 'cfMaterial', 'doorGap', 'doorReveal', 'doorDistance', 'frontRadius', 'doorHeightAdjust', 'drawerHeightAdjust', 'fingerGapGlobal', 'fingerAllGlobal', 'liveCabinet', 'liveSizes', 'resizeNeighbours', 'thickness', 'backThickness', 'topPanel',
    'handle', 'drawerHandle', 'handleLength', 'handleOrientation', 'handleHPlace', 'handleSide', 'handleVert', 'handleMaterial',
    'baseMaterial', 'wallMaterial', 'tallMaterial', 'carcassMaterial',
    'toeHeight', 'toeThickness', 'toeRecess', 'pieceLength', 'toeMaterial', 'toeCover',
    'wtThickness', 'wtFront', 'wtEnd', 'wtRound', 'wtSplash', 'wtMaterial', 'wtSplashMaterial',
    'wbThickness', 'wbLength', 'wbSetback', 'wbLoftSetback', 'wbMaterial'
  ];

  function gatherPresets() {
    const values = {};
    PRESET_IDS.forEach((id) => {
      const el = $(id);
      if (!el) return;
      if (el.type === 'checkbox') values[id] = el.checked;
      else if (LENGTH_IDS.includes(id)) {
        const text = String(mmv(id)).trim();
        const mm = Number(text);
        if (text !== '' && Number.isFinite(mm)) values[id] = mm;
      } else values[id] = el.value;
    });
    return values;
  }

  function schedulePresetSave() {
    if (!state.presetsReady) return; // not until what was saved has been put back
    clearTimeout(state.presetTimer);
    state.presetTimer = setTimeout(() => {
      call('save_presets', { values: gatherPresets() }).catch(() => { /* saving is a convenience */ });
    }, 700);
  }

  async function restorePresets() {
    try {
      const res = await call('load_presets');
      const saved = res.ok && res.data ? res.data.values || {} : {};
      const put = (id) => {
        const el = $(id);
        if (!el || !(id in saved)) return;
        if (el.type === 'checkbox') el.checked = saved[id] === true;
        else if (LENGTH_IDS.includes(id) && typeof saved[id] === 'number') setText(id, saved[id]);
        else if (el.tagName === 'SELECT') setSelect(id, saved[id]);
        else el.value = String(saved[id]);
      };
      if ('units' in saved && UNITS[saved.units]) setUnit(saved.units); // first: every length below is shown in it
      put('handle');
      onHandleChange(false); // the handle brings its own lengths and finishes
      PRESET_IDS.filter((id) => id !== 'units' && id !== 'handle').forEach(put);
      syncHandlePosition();
      syncThicknessPresets();
      updateChips();
    } catch (_) { /* the panel starts from the standard values */ }
    state.presetsReady = true;
  }

  // The cut list table, in the chosen unit.
  function renderCutList(data) {
    const rows = list(data.rows);
    const table = $('cutList');
    const unit = unitInfo().label;
    table.innerHTML = '';
    const head = table.createTHead().insertRow();
    ['Part', `Length (${unit})`, `Width (${unit})`, `Thickness (${unit})`, 'Material', 'Qty', 'Cabinet'].forEach((text) => {
      const cell = document.createElement('th');
      cell.textContent = text;
      head.append(cell);
    });
    const body = table.createTBody();
    rows.forEach((r) => {
      const tr = body.insertRow();
      [r.part, r.length ? fmtU(r.length) : '', r.width ? fmtU(r.width) : '', r.thickness ? fmtU(r.thickness) : '', r.material, r.quantity, r.used_in].forEach((value) => {
        tr.insertCell().textContent = value === undefined || value === null ? '' : String(value);
      });
    });
    const areas = list(data.areas).map((a) => `${a.material || 'no material'} ${fmtU(a.thickness)} thick: ${a.area} m2`);
    $('cutListAreas').textContent = areas.length ? `Sheet area: ${areas.join('; ')}.` : '';
    $('cutListWrap').hidden = rows.length === 0;
  }

  // Which form an action reads. Each Insert button belongs to its own block;
  // Update follows whatever is selected in the model.
  const COLLECTORS = {
    rotate: () => ({ degrees: $('rotateDegrees').value }),
    worktop: () => collectWorktop(),
    cutlist: () => ({ group: $('cutGroup').checked }),
    wall_bottom: () => ({ wall_bottom_thickness: mmv('wbThickness'), wall_bottom_length: mmv('wbLength'), wall_bottom_setback: mmv('wbSetback'), wall_bottom_loft_setback: mmv('wbLoftSetback'), wall_bottom_material: $('wbMaterial').value, selected_only: state.wallBottomSelected }),
    cabinet: () => collect(),
    filler: () => collectFiller(),
    end_panel: () => collectEndPanel(),
    toe_kick: () => collectToeKick(),
    panel: () => collectPanel(),
    ceiling_filler: () => collectCeilingFiller()
  };

  // Filler, Side Panel, Toe Kick and Wall Bottom Panel are choices in the Category list, next
  // to the real cabinet categories.
  const PART_CATEGORIES = ['filler', 'end_panel', 'toe_kick', 'wall_bottom', 'panel', 'ceiling_filler'];

  // The category of what is built: a loft unit is a wall unit.
  function catId() {
    const value = $('category').value;
    return value === 'loft' ? 'wall' : value;
  }

  function categoryKind() {
    const value = $('category').value;
    return PART_CATEGORIES.includes(value) ? value : 'cabinet';
  }

  // The main Insert button inserts whatever the Cabinet Category says; Update
  // follows whatever is selected in the model.
  function formKind(action) {
    if (action === 'apply_worktop') return 'worktop';
    if (action === 'apply_wall_bottom') return 'wall_bottom';
    if (action === 'get_cut_list' || action === 'export_cut_list') return 'cutlist';
    if (action === 'insert') return categoryKind();
    if (action === 'insert_at_point' || action === 'insert_on_path') return 'cabinet'; // (the cabinet of the panel, put where you click)
    if (action === 'insert_exposed_side_panels') return 'end_panel';
    if (action === 'update') return state.selectedKind || categoryKind();
    if (action === 'rotate') return 'rotate';
    return null;
  }

  // Cabinets have their own Insert / Update / Delete; a filler, side panel or toe
  // kick has its own Insert and shares one Update / Delete (update_part / delete_part).
  const INSERT_ACTION = { cabinet: 'insert', filler: 'insert_filler', end_panel: 'insert_end_panel', toe_kick: 'insert_toe_kick', wall_bottom: 'apply_wall_bottom', panel: 'insert_panel', ceiling_filler: 'apply_ceiling_fillers' };

  // Removing a cabinet from your own catalog says which one.
  // The door and the windows of the Room card, as the list Ruby wants.
  function roomOpenings() {
    const one = (kind, prefix, sill) => ({ kind, on: $(`${prefix}On`).checked, wall: $(`${prefix}Wall`).value, from: mmv(`${prefix}From`), width: mmv(`${prefix}Width`), sill, height: mmv(`${prefix}Height`) });
    return [one('Door', 'roomDoor', '0'), one('Window', 'roomWin1', mmv('roomWin1Sill')), one('Window', 'roomWin2', mmv('roomWin2Sill'))];
  }

  const CATALOG_PAYLOAD = {
    delete: () => (categoryKind() === 'wall_bottom' ? { when_empty: 'remove_wall_bottom' } : {}), // (Delete takes what is selected; with nothing selected, the bottom panels)
    add_material: () => ({ from: $('myFrom').value, name: $('myName').value, category: $('myCat').value }),
    remove_material: () => ({ name: $('myRemove').value }),
    remove_from_catalog: () => ({ catalog_id: catalog.value, cabinet_category: category.value, cabinet_type: cabinet.value }),
    remove_handle: () => ({ handle_id: $('handle').value }),
    design_kitchen: () => ({ kitchen: collectKitchen(), cabinet: collect(), worktop: $('kitchenWorktop').checked ? collectWorktop() : null,
      toe_kick: $('kitchenToeKick').checked ? collectToeKick() : null, end_panel: $('kitchenEndPanels').checked || $('kitchenIslandSidePanels').checked ? collectEndPanel() : null }),
    design_kitchen_options: () => CATALOG_PAYLOAD.design_kitchen(),
    add_appliance: () => ({ kind: $('applianceKind').value, front: $('applianceFront').value }),
    remove_appliance: () => ({ kind: $('applianceKind').value }),
    build_room: () => ({ wall_thickness: mmv('roomWall'), floor_thickness: mmv('roomFloor'), roof_thickness: mmv('roomRoof'), room_height: mmv('roomHeight'), open_x: mmv('roomOpenX'), open_y: mmv('roomOpenY'), openings: roomOpenings(), floor: $('roomFloorOn').checked, walls: $('roomWallsOn').checked, roof: $('roomRoofOn').checked }),
    design_path_kitchen: () => ({ ...CATALOG_PAYLOAD.design_kitchen(), flip: $('kitchenPathFlip').checked })
  };

  // A front design chosen from the list goes on the selected cabinets (every cabinet when none is selected).
  async function applyGlassDesign() {
    try {
      const res = await call('apply_glass_design', { glass_design: $('glassDoor').value });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  async function applyFrontDesign() {
    try {
      const res = await call('apply_front_design', { front_design: $('frontDesign').value });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  // Adding to or removing from your own materials changes every material list.
  function materialsChanged(data, action) {
    if (!data.materials) return;
    loadMaterials(data.materials);
    if (action === 'add_material') { $('myName').value = ''; $('myFrom').value = ''; }
  }

  // My Appliances: which kinds are your own model, and which are the drawn ones.
  function appliancesChanged(data) {
    if (Array.isArray(data.my_appliances)) state.meta.my_appliances = data.my_appliances;
    renderAppliances();
  }

  function renderAppliances() {
    const kinds = list(state.meta.my_appliances);
    const select = $('applianceKind');
    if (!select) return;
    if (!select.options.length) kinds.forEach((kind) => select.append(new Option(kind.name, kind.id)));
    const chosen = kinds.find((kind) => kind.id === select.value);
    const mine = kinds.filter((kind) => kind.custom).map((kind) => kind.name);
    const own = chosen && chosen.custom;
    $('applianceState').textContent = `${chosen ? `${chosen.name}: ${own ? `your model "${chosen.file}" is used` : 'the drawn one is used'}.` : ''} ${mine.length ? `Your own: ${mine.join(', ')}.` : 'None uploaded yet.'}`;
    if (own && chosen.front) $('applianceFront').value = chosen.front;
  }

  // Adding or removing a handle of your own changes the Handle lists (the new one is chosen).
  function handlesChanged(data, action) {
    if (!Array.isArray(data.handle_bundles)) return;
    state.meta.handle_bundles = data.handle_bundles.map((b) => Object.assign({ lengths: [], finishes: [], defaults: {}, profile: 'bar' }, b));
    const doors = $('handle').value;
    const drawers = $('drawerHandle').value;
    applyCatalogFeatures();
    const has = (id) => state.meta.handle_bundles.some((b) => b.id === id);
    if (action === 'add_handle' && data.handle_id) {
      setSelect('handle', data.handle_id);
      setTimeout(() => $('handle').dispatchEvent(new Event('change', { bubbles: true })), 0); // (as if it was picked in the list: it is put on the cabinets)
    } else {
      setSelect('handle', has(doors) ? doors : '');
      setSelect('drawerHandle', has(drawers) ? drawers : '');
    }
    onHandleChange(true);
    lockActions();
  }

  // Saving to or removing from your own catalogs changes the list of models.
  async function catalogsChanged(data, action) {
    if (!Array.isArray(data.catalogs)) return;
    state.meta.catalogs = data.catalogs;
    const wanted = catalog.value;
    fillSelect(catalog, state.meta.catalogs, { placeholder: 'Select a model...' });
    if (!state.meta.catalogs.some((c) => c.id === wanted)) {
      catalog.value = '';
      applyCatalogFeatures();
      await refreshCabinets();
    } else if (action === 'remove_from_catalog') {
      await refreshCabinets({ keepValues: true });
    }
    lockActions();
  }

  // The answers of the Auto Kitchen section.
  function collectKitchen() {
    return {
      style: $('kitchenStyle').value, mirror: $('kitchenMirror').checked, layout: $('kitchenLayout').value, wall_a: mmv('kitchenWallA'), wall_b: mmv('kitchenWallB'), wall_c: mmv('kitchenWallC'), fridge: $('kitchenFridge').value, variation: $('kitchenVariation').value, sink_wall: $('kitchenSinkWall').value, hob_wall: $('kitchenHobWall').value,
      sink: $('kitchenSink').checked, sink_bowls: $('kitchenSinkType').value[0], sink_drain: $('kitchenSinkType').value[1] === 'd', dishwasher: $('kitchenDish').checked, dishwasher_handle: $('kitchenDishHandle').checked, hob: $('kitchenHob').checked, hood: $('kitchenHood').checked, oven_tower: $('kitchenOven').checked,
      wall_units: $('kitchenWall').checked, island: $('kitchenIsland').checked, island_wall: $('kitchenIslandWall').value, island_length: mmv('kitchenIslandLength'), island_aisle: mmv('kitchenIslandAisle'), island_feature: $('kitchenIslandFeature').value, island_seating: $('kitchenIslandSeating').value, island_back_panel: $('kitchenIslandBackPanel').checked, island_mirror: $('kitchenIslandMirror').checked, panel_thickness: $('kitchenEndPanels').checked ? mmv('epThickness') : 0, island_back_panel_material: $('kitchenBackPanelMaterial').value, island_side_panels: $('kitchenIslandSidePanels').checked, open_ends: $('kitchenEndPanels').checked, run_end_panels: $('kitchenEndPanels').checked, island_hood_colour: $('kitchenHoodColour').value,
      windows: [1, 2].map((n) => ({ wall: $('kitchenWin' + n + 'Wall').value, from: mmv('kitchenWin' + n + 'From'), width: mmv('kitchenWin' + n + 'Width') })).filter((w) => w.wall)
    };
  }

  function serverAction(action) {
    const isPart = state.selectedKind && state.selectedKind !== 'cabinet';
    if (isPart && action === 'update') return 'update_part';
    if (!state.selectedKind && categoryKind() === 'wall_bottom' && action === 'update') return 'apply_wall_bottom'; // (Category = Wall Bottom Panel: Update draws the panels again)
    if (action === 'insert') return INSERT_ACTION[categoryKind()];
    return action;
  }

  /* ---------------------------------------------------------------------- *
   * Small helpers
   * ---------------------------------------------------------------------- */

  function num(value) {
    const n = parseFloat(String(value).trim().replace(',', '.'));
    return Number.isFinite(n) ? n : NaN;
  }

  function fmt(n) {
    if (!Number.isFinite(n)) return '';
    return Number.isInteger(n) ? String(n) : String(Math.round(n * 10) / 10);
  }

  /* ---------------------------------------------------------------------- *
   * Units: the panel shows lengths in the chosen unit; SketchUp always gets mm
   * ---------------------------------------------------------------------- */

  const UNITS = {
    mm: { name: 'Millimetres (mm)', label: 'mm', mm: 1, decimals: 1 },
    cm: { name: 'Centimetres (cm)', label: 'cm', mm: 10, decimals: 2 },
    m: { name: 'Metres (m)', label: 'm', mm: 1000, decimals: 4 },
    in: { name: 'Inches (in)', label: 'in', mm: 25.4, decimals: 3 },
    ft: { name: 'Feet (ft)', label: 'ft', mm: 304.8, decimals: 4 }
  };

  // The inputs that hold a length. Each one's text is in the chosen unit.
  const LENGTH_IDS = [
    'doorGap', 'doorReveal', 'doorDistance', 'frontRadius', 'doorHeightAdjust', 'drawerHeightAdjust', 'thickness', 'backThickness',
    'width', 'depth', 'height', 'kitchenWallA', 'kitchenWallB', 'kitchenWallC', 'kitchenIslandLength', 'kitchenIslandAisle', 'kitchenWin1From', 'kitchenWin1Width', 'kitchenWin2From', 'kitchenWin2Width', 'carcassRaise', 'leg2Length', 'leg2Depth', 'ovenHeight', 'ovenHeight2', 'microHeight', 'zoneHeight', 'bottomHeight', 'topFrontHeight', 'fridgeHeight', 'smallDrawer', 'blindWidth', 'splitHeight', 'liftHeight', 'fingerGapGlobal', 'drawerH1', 'drawerH2', 'drawerH3', 'drawerH4', 'drawerH5', 'drawerH6', 'wbThickness', 'wbLength', 'wbSetback', 'wbLoftSetback', 'gap', 'toeHeight', 'handleSide', 'handleVert', 'handleCustomX', 'handleCustomZ',
    'fillerWidth', 'fillerThickness', 'fillerHeight', 'epDepth', 'epThickness', 'epHeight',
    'toeThickness', 'toeRecess', 'pieceLength', 'wtThickness', 'wtFront', 'wtEnd', 'wtRound', 'wtPiece', 'wtSplash',
    'cfHeight', 'cfThickness', 'cfRecess', 'cfPiece', 'pCfHeight', 'pCfThickness', 'pCfRecess', 'panelWidth', 'panelLength', 'panelThickness', 'pToeHeight', 'pToeThickness', 'pToeRecess', 'sizeBaseW', 'sizeBaseD', 'sizeBaseH', 'sizeWallW', 'sizeWallD', 'sizeWallH', 'sizeTallW', 'sizeTallD', 'sizeTallH', 'sizeLoftW', 'sizeLoftD', 'sizeLoftH',
    'roomWall', 'roomFloor', 'roomRoof', 'roomHeight', 'roomOpenX', 'roomOpenY',
    'roomDoorFrom', 'roomDoorWidth', 'roomDoorHeight',
    'roomWin1From', 'roomWin1Width', 'roomWin1Sill', 'roomWin1Height', 'roomWin2From', 'roomWin2Width', 'roomWin2Sill', 'roomWin2Height'
  ];

  function unitInfo() { return UNITS[state.unit] || UNITS.mm; }

  // mm -> text in the chosen unit (no unit label), trimmed of trailing zeros.
  function fmtU(mm) {
    if (!Number.isFinite(mm)) return '';
    const { decimals, mm: factor } = unitInfo();
    const scaled = mm / factor;
    const rounded = Math.round(scaled * 10 ** decimals) / 10 ** decimals;
    return String(rounded);
  }

  function fmtLen(mm) { return `${fmtU(mm)} ${unitInfo().label}`; }

  // The length typed in a field, in mm, as text. A field nobody has edited since it
  // was filled gives back the exact mm it was filled with, so converting to inches
  // and back never drifts the size of a cabinet.
  function mmv(id) {
    const el = $(id);
    const text = el.value.trim();
    if (!text) return '';
    if (el.dataset.mm !== undefined && el.dataset.shown === el.value) return el.dataset.mm;
    const n = num(text);
    return Number.isFinite(n) ? String(Math.round(n * unitInfo().mm * 1e6) / 1e6) : text;
  }

  function showLength(id, mm) {
    const el = $(id);
    el.value = fmtU(mm);
    el.dataset.mm = String(mm);
    el.dataset.shown = el.value;
  }

  function refreshUnitLabels() {
    LENGTH_IDS.forEach((id) => {
      const el = $(id);
      const label = el && el.parentElement && el.parentElement.querySelector('em');
      if (label) label.textContent = unitInfo().label;
    });
  }

  // Switching unit re-writes every length in the new unit (same sizes, other numbers).
  function setUnit(unit) {
    if (!UNITS[unit] || unit === state.unit) return;
    const values = LENGTH_IDS.map((id) => [id, mmv(id)]);
    const cuts = cutsToMm();
    state.unit = unit;
    values.forEach(([id, mm]) => {
      const n = num(mm);
      if (mm !== '' && Number.isFinite(n)) showLength(id, n);
    });
    showCuts(cuts);
    refreshUnitLabels();
    fillWidthPreset();
    fillThicknessPresets();
    [...$('handleLength').options].forEach((o) => { if (o.value) o.textContent = fmtLen(Number(o.value)); });
    $('units').value = unit;
    try { localStorage.setItem('ec.unit', unit); } catch (_) { /* a private window: not remembered */ }
    drawPreview();
  }
  // Fills a list. The lists have no headings: an item that comes with a `group` (a kind or a category) is put with the others of its group, in the
  // order the groups first appear, and in the order given within a group; so whatever is added later to a list sits with its own kind.
  function fillSelect(el, items, { placeholder = null } = {}) {
    const previous = el.value;
    el.innerHTML = '';
    if (placeholder) el.append(new Option(placeholder, ''));
    const entries = list(items);
    const order = [];
    entries.forEach((item) => { if (item.group && !order.includes(item.group)) order.push(item.group); });
    const rank = (item) => (item.group ? order.indexOf(item.group) : -1);
    entries
      .map((item, index) => ({ item, index }))
      .sort((a, b) => (rank(a.item) - rank(b.item)) || (a.index - b.index))
      .forEach(({ item }) => el.append(new Option(item.name, item.id)));
    if ([...el.options].some((o) => o.value === previous)) el.value = previous;
  }
  function setSelect(id, value) {
    const el = $(id);
    const text = String(value === undefined || value === null ? '' : value);
    if ([...el.options].some((o) => o.value === text)) el.value = text;
  }

  // The Toe Kick fields of the Presets (under the Tall Unit sizes) and those of Cabinet and Extras are the same values.
  const TOE_PRESET = { toeHeight: 'pToeHeight', toeThickness: 'pToeThickness', toeRecess: 'pToeRecess', cfHeight: 'pCfHeight', cfThickness: 'pCfThickness', cfRecess: 'pCfRecess' };
  const TOE_FROM_PRESET = { pToeHeight: 'toeHeight', pToeThickness: 'toeThickness', pToeRecess: 'toeRecess', pCfHeight: 'cfHeight', pCfThickness: 'cfThickness', pCfRecess: 'cfRecess' };
  function mirrorToe(id) {
    if (TOE_PRESET[id] && $(TOE_PRESET[id])) $(TOE_PRESET[id]).value = $(id).value;
  }

  function setText(id, value) {
    if (value === undefined || value === null) return;
    if (LENGTH_IDS.includes(id) && typeof value === 'number') {
      showLength(id, value);
      mirrorToe(id);
      return;
    }
    $(id).value = typeof value === 'number' ? fmt(value) : String(value);
    mirrorToe(id);
  }

  /* ---------------------------------------------------------------------- *
   * Catalog features: what the selected catalog switches on
   * ---------------------------------------------------------------------- */

  const ALL_FEATURES = [
    'base', 'wall', 'tall', 'corner', 'filler', 'end_panel', 'toe_kick',
    'door_gap', 'door_reveal', 'door_distance', 'front_radius', 'top_panel', 'panel_thickness', 'back_thickness',
    'cabinet_extras', 'worktop', 'handle', 'materials', 'door_opening', 'visibility', 'rotate'
  ];

  function currentCatalog() {
    return list(state.meta && state.meta.catalogs).find((c) => c.id === $('catalog').value) || null;
  }

  // A catalog's old id (see "aliases" in its file) means the same catalog.
  function resolveCatalogId(id) {
    const found = list(state.meta && state.meta.catalogs).find((c) => c.id === id || list(c.aliases).includes(id));
    return found ? found.id : id;
  }

  // Only what the selected catalog offers is active: its categories and options,
  // its handle bundles. Everything else stays visible but greyed out and locked.
  function applyCatalogFeatures() {
    const catalog = currentCatalog();
    // No catalog chosen yet: nothing is active except the catalog selection itself.
    const on = new Set(!catalog ? [] : (Array.isArray(catalog.features) ? catalog.features : ALL_FEATURES));

    const categories = [...list(state.meta.categories), { id: 'filler', name: 'Filler' }, { id: 'end_panel', name: 'Side Panel' }, { id: 'toe_kick', name: 'Toe Kick' }, { id: 'wall_bottom', name: 'Wall Bottom Panel' }, { id: 'panel', name: 'Panel' }, { id: 'ceiling_filler', name: 'Ceiling Filler' }];
    fillSelect($('category'), categories.filter((c) => on.has(c.id === 'wall_bottom' || c.id === 'loft' || c.id === 'ceiling_filler' ? 'wall' : c.id)));

    document.querySelectorAll('[data-feature]').forEach((el) => {
      const off = !on.has(el.dataset.feature);
      el.classList.toggle('feature-off', off);
      el.querySelectorAll('input, select, button:not(.card-head):not(.card-move)').forEach((control) => {
        if (off && !control.disabled) {
          control.disabled = true;
          control.dataset.featureLocked = '1';
        } else if (!off && control.dataset.featureLocked) {
          control.disabled = false;
          delete control.dataset.featureLocked;
        }
      });
      if (off && el.classList.contains('card')) toggleCard(el, false);
    });

    const allowed = catalog && Array.isArray(catalog.handle_bundles) ? catalog.handle_bundles : null;
    const before = $('handle').value;
    const offered = arrangeHandles(list(state.meta.handle_bundles).filter((b) => !allowed || allowed.includes(b.id)));
    fillSelect($('handle'), offered, { placeholder: 'None' });
    fillSelect($('drawerHandle'), offered, { placeholder: 'Same as doors' });
    // A cabinet comes with a handle: the first one the model offers, unless one is already chosen.
    if (catalog && !$('handle').value && $('handle').options.length > 1) $('handle').selectedIndex = 1;
    if ($('handle').value !== before) onHandleChange(true);
    // The Gola handle model: the drawers have Gola System C Plus to begin with (between the drawer fronts), the doors the first one of the list.
    const golaNow = !!(catalog && catalog.gola);
    if (golaNow && !state.wasGola && !$('drawerHandle').value && [...$('drawerHandle').options].some((o) => o.value === 'gola_c_plus')) setSelect('drawerHandle', 'gola_c_plus');
    state.wasGola = golaNow;
    syncZoneField();
    lockActions();
  }

  // Insert needs a catalog: it builds a cabinet from the selected catalog's style.
  function lockActions() {
    gateUntilModel();
    const insert = document.querySelector('[data-action="insert"]');
    if (insert) insert.disabled = state.busy || !currentCatalog();
    const remove = removeFromCatalog;
    if (remove) remove.disabled = state.busy || !(currentCatalog() || {}).custom || !cabinet.value; // only your own catalogs
    ['designKitchen', 'designKitchenOptions'].forEach((id) => { const button = $(id); if (button) button.disabled = state.busy || !currentCatalog(); }); // the kitchen is built from a model's units
    const removeOwn = $('removeHandle');
    if (removeOwn) removeOwn.disabled = state.busy || !(currentBundle() || {}).custom; // only handles you added
  }

// Until a model is chosen (Models card) everything else is inactive: the other cards and the bar above.
function gateUntilModel() {
  const off = !currentCatalog();
  document.querySelectorAll('.topbar-row:not(:first-child), main.scroll > section:not(#sec-catalog), .actions').forEach((el) => {
    el.classList.toggle('gated', off);
    if (off) el.setAttribute('inert', ''); else el.removeAttribute('inert');
  });
}

function currentCabinet() {
    return state.cabinets.find((c) => c.id === $('cabinet').value) || null;
  }

  /* ---------------------------------------------------------------------- *
   * Materials
   * ---------------------------------------------------------------------- */

  function loadMaterials(materials) {
    const panel = list(materials && materials.panel);
    const toeKick = list(materials && materials.toe_kick);
    const glass = list(materials && materials.glass);
    fillMine(materials, panel);
    state.colors = {};
    state.textures = {};
    [...panel, ...toeKick, ...glass].forEach((m) => {
      if (m.color) state.colors[m.id] = m.color;
      if (m.texture) state.textures[m.id] = m.texture; // the picture of a wood, stone or metal
    });
    ['baseMaterial', 'wallMaterial', 'tallMaterial'].forEach((id) => fillSelect($(id), panel));
    fillSelect($('carcassMaterial'), panel, { placeholder: 'Same as door material' });
    fillSelect($('handleMaterial'), panel, { placeholder: "Use the finish's material" });
    fillSelect($('kitchenBackPanelMaterial'), panel, { placeholder: 'Same as the doors' });
    fillSelect($('toeMaterial'), toeKick);
    fillSelect($('epMaterial'), [{ id: '__door__', name: 'Same as door material' }, ...panel]);
    fillSelect($('panelMaterial'), [{ id: '__door__', name: 'Same as door material' }, ...panel]);
    fillSelect($('cfMaterial'), [{ id: '__door__', name: 'Same as door material' }, ...panel]);
    fillSelect($('wtMaterial'), panel);
    fillSelect($('glassMaterial'), glass.length ? glass : [{ id: 'Glass - Clear', name: 'Glass - Clear' }]);
    fillSelect($('wtSplashMaterial'), [{ id: '__same__', name: 'Same as worktop' }, ...panel]);
    fillSelect($('wbMaterial'), [{ id: '__door__', name: 'Same as wall unit door material' }, ...panel]);
    updateChips();
  }

  // Your own materials: the lists in the My materials block (a new colour or a material of the model to start from; the ones to remove).
  function fillMine(materials, panel) {
    const mine = list(materials && materials.mine);
    fillSelect($('myFrom'), panel.filter((m) => m.group === 'In this model'), { placeholder: 'Choose a material of the model...' });
    fillSelect($('myRemove'), mine.map((m) => ({ id: m.id, name: `${m.name} (${m.category})` })), { placeholder: mine.length ? 'Choose...' : 'None yet' });
    const cats = $('myCats');
    cats.innerHTML = '';
    [...new Set(mine.map((m) => m.category))].forEach((c) => cats.append(new Option(c)));
    const remove = $('removeMaterial');
    if (remove) remove.disabled = state.busy || !mine.length;
  }

  function updateChips() {
    document.querySelectorAll('[data-chip-for]').forEach((chip) => {
      const select = $(chip.dataset.chipFor);
      const map = select && select.id === 'handleFinish' ? state.finishColors : state.colors;
      const color = select ? map[select.value] : null;
      const picture = select && state.textures ? state.textures[select.value] : null;
      if (color) {
        chip.style.background = color;
        if (picture) { chip.style.backgroundImage = picture.startsWith('file:') ? `url(${picture})` : `url(../data/textures/${picture})`; chip.style.backgroundSize = 'cover'; }
        chip.dataset.color = color;
      } else {
        chip.style.background = '';
        delete chip.dataset.color;
      }
    });
  }

  async function refreshMaterials() {
    if (!state.meta || Date.now() - state.lastMaterialRefresh < 1500) return;
    state.lastMaterialRefresh = Date.now();
    try {
      const res = await call('get_materials');
      if (res.ok) loadMaterials(res.data.materials);
    } catch (_) { /* the panel keeps working with the list it has */ }
  }

  /* ---------------------------------------------------------------------- *
   * Form <-> parameters
   * ---------------------------------------------------------------------- */

  function collect() {
    const withHandle = !!$('handle').value;
    const handleValue = (id) => (withHandle ? $(id).value : '');
    return {
      catalog_id: $('catalog').value,
      resize_neighbours: $('resizeNeighbours').checked,
      front_design: $('frontDesign').value,
      glass_design: $('glassDoor').value,
      glass_doors: $('glassDoors').value,
      handle_id: $('handle').value,
      drawer_handle_id: $('drawerHandle').value,
      base_material: $('baseMaterial').value,
      wall_material: $('wallMaterial').value,
      tall_material: $('tallMaterial').value,
      material_thickness: mmv('thickness'),
      back_thickness: mmv('backThickness'),
      door_gap: mmv('doorGap'),
      door_distance: mmv('doorDistance'),
      front_radius: mmv('frontRadius'),
      top_panel_style: $('topPanel').value,
      door_opening_direction: $('direction').value,
      door_opening_angle: $('angle').value,
      symbol_angle: $('symbolAngle').value,
      show_opening_direction: $('showDirection').checked,
      show_door_symbol: $('showDoorSymbol').checked,
      show_wall_opening_direction: $('showWallDirection').checked,
      hide_wall_handles: !$('hideWallHandles').checked, // the tick says Show
      show_cabinet_names: $('showNames').checked,
      hide_base_handles: !$('hideBaseHandles').checked, // the tick says Show
      hide_tall_handles: !$('hideTallHandles').checked, // the tick says Show
      hide_loft_handles: !$('hideLoftHandles').checked, // the tick says Show
      door_reveal: mmv('doorReveal'),
      cabinet_category: $('category').value,
      cabinet_type: $('cabinet').value,
      placement_gap: mmv('gap'),
      width: mmv('width'),
      depth: mmv('depth'),
      height: mmv('height'),
      carcass_raise: mmv('carcassRaise'),
      door_height_adjust: mmv('doorHeightAdjust'),
      drawer_height_adjust: mmv('drawerHeightAdjust'),
      leg2_length: mmv('leg2Length'),
      leg2_depth: mmv('leg2Depth'),
      appliance_set: isApplianceCabinet() ? $('applianceSet').value : '',
      front_zone: hasZoneField() ? mmv('zoneHeight') : '',
      oven_height: mmv('ovenHeight'),
      oven2_height: mmv('ovenHeight2'),
      bottom_zone: hasBottomField() ? mmv('bottomHeight') : '',
      top_front: hasTopFrontField() ? mmv('topFrontHeight') : '',
      fridge_height: hasFridgeField() ? mmv('fridgeHeight') : '',
      fridge_lift: $('liftUp').checked,
      door_split: hasSplitField() && $('doorSplit').value === 'split',
      split_height: hasSplitField() ? mmv('splitHeight') : '',
      housing_lift: hasLiftField() ? mmv('liftHeight') : '',
      finger_gap: hasFingerField() ? mmv('fingerGapGlobal') : '', // the Presets setting: doors and drawers alike
      finger_gap_drawer: hasFingerField() ? mmv('fingerGapGlobal') : '',
      finger_all: hasFingerField() && $('fingerAllGlobal').checked,
      glass_material: $('glassMaterial').value,
      lift_door: hasLiftTick() && $('liftDoor').checked, // a glass door unit can lift up instead of swinging
      drawer_heights: hasDrawerHeights() ? collectDrawerHeights() : '',
      drawer_number: hasDrawerHeights() ? String(drawerCount()) : '',
      sink_bowls: $('sinkBowls').value,
      sink_tray: $('sinkTray').checked,
      sink_mirror: $('sinkMirror').checked,
      blind_width: hasBlindField() ? mmv('blindWidth') : '',
      dividers: hasWardrobeField() ? $('dividers').value : '',
      rail: hasWardrobeField() ? $('wardrobeRail').checked : '',
      lower_mode: hasLowerField() ? $('lowerMode').value : '',
      lower_drawers: $('lowerDrawers').value,
      small_drawer: mmv('smallDrawer'),
      micro_height: mmv('microHeight'),
      shelf_count: hasShelvesField() ? $('shelves').value : '0',
      carcass_material: $('carcassMaterial').value,
      toe_kick_height: mmv('toeHeight'),
      handle_length: handleValue('handleLength'),
      handle_finish: handleValue('handleFinish'),
      handle_material: handleValue('handleMaterial'),
      handle_orientation: handleValue('handleOrientation'),
      handle_position: handleValue('handlePosition'),
      handle_horizontal_place: handleValue('handleHPlace'),
      handle_side_offset: handleValue('handleSide'),
      handle_vertical_offset: handleValue('handleVert'),
      handle_custom_x: handleValue('handleCustomX'),
      handle_custom_z: handleValue('handleCustomZ'),
      visibility_settings: {
        carcass: $('visCarcass').checked,
        door: $('visDoor').checked,
        toe_kick: $('visToe').checked,
        appliances: $('showAppliances').checked,
        oven: $('showOven').checked,
        microwave: $('showMicro').checked,
        sink: $('showSink').checked,
        hob: $('showHob').checked,
        hood: $('showHood').checked,
        free_fridge: $('showFreeFridge').checked
      }
    };
  }

  // The drawer heights typed, top to bottom, as one list ("300,,": a blank one is left to share).
  function collectDrawerHeights() {
    const count = Math.min(6, Number((currentCabinet() || {}).drawers) || 0);
    const list = [];
    for (let i = 1; i <= count; i += 1) list.push(String(mmv(`drawerH${i}`)).trim());
    return list.some((v) => v !== '') ? list.join(',') : '';
  }

  function applyParams(stored) {
    const p = stored.toe_kick_material === '__cabinet__' ? Object.assign({}, stored, { toe_kick_material: '__door__' }) : stored;
    if ('handle_id' in p) {
      setSelect('handle', p.handle_id || '');
      onHandleChange(false);
    }
    if ('drawer_handle_id' in p) setSelect('drawerHandle', p.drawer_handle_id || '');
    Object.entries(TEXT_PARAMS).forEach(([key, id]) => {
      // A wall unit stores a toe-kick height of 0 (it hangs); that must not become the
      // starting height of the next base or tall unit, which stand on a 100 mm toe kick.
      if (key === 'toe_kick_height' && p.cabinet_category === 'wall') return;
      if (key in p) setText(id, p[key]);
    });
    setText('carcassRaise', Number(p.carcass_raise) || 0); // a cabinet saved before this option has none
    setText('doorHeightAdjust', Number(p.door_height_adjust) || 0);
    setText('drawerHeightAdjust', Number(p.drawer_height_adjust) || 0);
    // An L-shaped corner has a second leg; 0 / missing means it is the same as the first.
    setText('leg2Length', Number(p.leg2_length) > 0 ? Number(p.leg2_length) : Number(p.width));
    setText('leg2Depth', Number(p.leg2_depth) > 0 ? Number(p.leg2_depth) : Number(p.depth));
    setSoft($('legFields'), p.corner_style !== 'l_shape');
    setLegLabels(p.corner_style === 'l_shape');
    // An oven housing: which appliances, and how tall they are.
    if (p.appliance_set) {
      setSelect('applianceSet', p.appliance_set);
      setText('ovenHeight', Number(p.oven_height) || 595);
      setText('ovenHeight2', Number(p.oven2_height) || 595);
      setText('microHeight', Number(p.micro_height) || 380);
    }
    syncApplianceFields(!!p.appliance_set);
    if (p.front_zone > 0 && hasZoneField()) setText('zoneHeight', p.front_zone);
    if (p.bottom_zone > 0 && hasBottomField()) setText('bottomHeight', p.bottom_zone);
    if (p.top_front > 0 && hasTopFrontField()) setText('topFrontHeight', p.top_front);
    if (p.fridge_height > 0 && hasFridgeField()) setText('fridgeHeight', p.fridge_height);
    $('liftUp').checked = p.fridge_lift !== false;
    if (hasSplitField()) {
      $('doorSplit').value = p.door_split ? 'split' : 'full';
      setText('splitHeight', Number(p.split_height) || (currentCabinet() || {}).split || 1000);
    }
    if (hasDrawerHeights()) setText('drawerCount', Number(p.drawer_count) || (currentCabinet() || {}).drawers || 1);
    if (hasLiftField()) setText('liftHeight', Number(p.housing_lift) || (currentCabinet() || {}).lift || 360);
    if (hasFingerField()) { setText('fingerGapGlobal', Number(p.finger_gap) || 35); $('fingerAllGlobal').checked = p.finger_all === true; }
    setSelect('glassMaterial', p.glass_material || 'Glass - Clear');
    $('liftDoor').checked = p.lift_door === true;
    const typedHeights = String(p.drawer_heights || '').split(',');
    for (let i = 1; i <= 6; i += 1) setText(`drawerH${i}`, Number(typedHeights[i - 1]) > 0 ? Number(typedHeights[i - 1]) : '');
    if (p.sink) {
      $('sinkBowls').value = String(p.sink_bowls || 1);
      $('sinkTray').checked = p.sink_tray === true;
      $('sinkMirror').checked = p.sink_mirror === true || Number(p.sink_rotation) === 180;
    }
    if (p.blind_width > 0 && hasBlindField()) setText('blindWidth', p.blind_width);
    if (p.wardrobe) { setText('dividers', Number(p.dividers) || 0); $('wardrobeRail').checked = p.rail === true; }
    if (hasLowerField()) {
      setSelect('lowerMode', p.lower_mode || 'drawers');
      setText('lowerDrawers', Number(p.lower_drawers) || Number(p.drawer_count) || 2);
      setText('smallDrawer', Number(p.small_drawer) || 180);
    }
    syncZoneField();
    Object.entries(SELECT_PARAMS).forEach(([key, id]) => {
      if (key in p) setSelect(id, p[key]);
    });
    if ('show_opening_direction' in p) $('showDirection').checked = !!p.show_opening_direction;
    if ('show_door_symbol' in p) $('showDoorSymbol').checked = !!p.show_door_symbol;
    if ('show_wall_opening_direction' in p) $('showWallDirection').checked = !!p.show_wall_opening_direction;
    if ('show_cabinet_names' in p) $('showNames').checked = !!p.show_cabinet_names;
    if ('hide_base_handles' in p) $('hideBaseHandles').checked = !p.hide_base_handles; // the tick says Show
    if ('hide_tall_handles' in p) $('hideTallHandles').checked = !p.hide_tall_handles; // the tick says Show
    if ('hide_loft_handles' in p) $('hideLoftHandles').checked = !p.hide_loft_handles; // the tick says Show
    if ('hide_wall_handles' in p) $('hideWallHandles').checked = !p.hide_wall_handles; // the tick says Show
    if (p.visibility_settings && typeof p.visibility_settings === 'object') {
      const v = p.visibility_settings;
      if ('carcass' in v) $('visCarcass').checked = !!v.carcass;
      if ('door' in v) $('visDoor').checked = !!v.door;
      if ('toe_kick' in v) $('visToe').checked = !!v.toe_kick;
      if ('appliances' in v) $('showAppliances').checked = true; // always shown
      if ('oven' in v) $('showOven').checked = !!v.oven;
      if ('microwave' in v) $('showMicro').checked = !!v.microwave;
      if ('sink' in v) $('showSink').checked = !!v.sink;
      if ('hob' in v) $('showHob').checked = !!v.hob;
      if ('hood' in v) $('showHood').checked = !!v.hood;
      if ('free_fridge' in v) $('showFreeFridge').checked = !!v.free_fridge;
    }
    syncHandlePosition();
    syncWidthPreset();
    syncThicknessPresets();
    updateChips();
    drawPreview();
  }

  /* ---------------------------------------------------------------------- *
   * Handle bundle options
   * ---------------------------------------------------------------------- */

  // The handle packages in order of what they are (bars, D handles and T bars, edge pulls, cups, knobs), as they are listed within one kind, with no
  // headings. A package of a kind not listed here goes after them.
  const HANDLE_KINDS = ['Bars', 'D handles & T bars', 'Edge pulls', 'Cups & shells', 'Knobs', 'My handles'];

  function arrangeHandles(bundles) {
    const rank = (b) => { const i = HANDLE_KINDS.indexOf(b.group); return i < 0 ? HANDLE_KINDS.length : i; };
    return list(bundles)
      .map((b, index) => ({ b, index }))
      .sort((x, y) => (rank(x.b) - rank(y.b)) || (x.index - y.index))
      .map(({ b }) => Object.assign({}, b, { group: undefined })); // (the group only says where it goes)
  }

  function currentBundle() {
    const id = $('handle').value;
    return (state.meta && list(state.meta.handle_bundles).find((b) => b.id === id)) || null;
  }

  // Fills Length / Finish from the chosen bundle. `useDefaults` also resets
  // orientation, position and offsets to the bundle's own defaults.
  function onHandleChange(useDefaults) {
    const bundle = currentBundle();
    setSoft($('handleOptions'), !bundle);
    if (!bundle) {
      drawPreview();
      return;
    }

    const finishes = list(bundle.finishes);
    fillSelect($('handleLength'), list(bundle.lengths).map((l) => ({ id: String(l), name: fmtLen(l) })));
    fillSelect($('handleFinish'), finishes);
    state.finishColors = {};
    finishes.forEach((f) => { if (f.color) state.finishColors[f.id] = f.color; });

    if (useDefaults) {
      const d = bundle.defaults || {};
      setSelect('handleLength', bundle.default_length);
      if (finishes[0]) $('handleFinish').value = finishes[0].id;
      setSelect('handleOrientation', d.orientation || 'horizontal');
      setSelect('handlePosition', d.position);
      setSelect('handleHPlace', d.horizontal_place || 'middle');
      setText('handleSide', d.side_offset);
      setText('handleVert', d.vertical_offset);
      setText('handleCustomX', d.custom_x);
      setText('handleCustomZ', d.custom_z);
    }
    ['handleSide', 'handleVert', 'handleHPlace'].forEach((id) => { $(id).disabled = EDGE_PROFILES.includes(bundle.profile) || bundle.profile === 'gola'; }); // an edge pull or a cup sits on the edge as its package says
    $('handleOrientation').disabled = bundle.profile === 'knob' || EDGE_PROFILES.includes(bundle.profile) || bundle.profile === 'gola'; // (a Gola profile is cut to the front and put where its system goes)
    $('handlePosition').disabled = bundle.profile === 'gola';
    $('handleLength').disabled = bundle.profile === 'gola';
    // a round knob has no orientation, an edge pull or a cup always runs along the edge
    syncHandlePosition();
    updateChips();
    drawPreview();
  }

  // Custom shows exact coordinates; otherwise the offsets apply. Only Top and
  // Bottom use the top/bottom offset.
  function syncHandlePosition() {
    const position = $('handlePosition').value;
    setSoft($('handleCustom'), position !== 'custom');
    setSoft($('handleOffsets'), position === 'custom');
    // Only a horizontal bar can sit in the middle of the door instead of at its edge.
    setSoft($('handleHPlaceField'), $('handleOrientation').value !== 'horizontal');
    // A horizontal handle centred across the door has no side to measure from.
    const centred = $('handleOrientation').value === 'horizontal' && $('handleHPlace').value === 'middle';
    setSoft($('handleSideField'), centred);
    setSoft($('handleVertField'), !['top', 'bottom', 'auto'].includes(position));
  }

  /* ---------------------------------------------------------------------- *
   * Catalog / category / cabinet
   * ---------------------------------------------------------------------- */

  // The cabinets of the Cabinet list are sorted into groups by what they are, in this order (and as listed within a group).
  const CABINET_GROUPS = ['Door units', 'Glass door units', 'Lift-up units', 'Glass lift-up units', 'Drawer units', 'Door and drawer units', 'Pull-outs', 'Sink units', 'Dishwasher space',
    'Hob, oven & hood', 'Fridge units', 'Open units', 'Corner units', 'My models'];

  function cabinetGroup(entry) {
    const drawers = Number(entry.drawers) || 0;
    const doors = Number(entry.doors) || 0;
    if (entry.component) return 'My models';
    if (entry.corner) return 'Corner units';
    if (entry.glass) return entry.lift_door || entry.bifold ? 'Glass lift-up units' : 'Glass door units';
    if (entry.lift_door || entry.bifold) return 'Lift-up units';
    if (entry.fridge || entry.free_housing || entry.freestanding) return 'Fridge units';
    if (entry.sink) return 'Sink units';
    if (entry.dishwasher) return 'Dishwasher space';
    if (entry.hob || entry.hood || entry.appliances || entry.lower) return 'Hob, oven & hood';
    if (entry.pullout) return 'Pull-outs';
    if (drawers > 0 && doors > 0) return 'Door and drawer units';
    if (drawers > 0) return 'Drawer units';
    if (doors > 0) return 'Door units';
    return 'Open units';
  }

  function groupCabinets(entries) {
    return list(entries)
      .map((entry, index) => ({ entry, index, group: cabinetGroup(entry) }))
      .sort((a, b) => (CABINET_GROUPS.indexOf(a.group) - CABINET_GROUPS.indexOf(b.group)) || (a.index - b.index))
      .map(({ entry }) => entry); // (in order, with no headings: a new kind of unit goes in with the others of its kind)
  }

  async function refreshCabinets({ selectId = null, keepValues = false } = {}) {
    if (categoryKind() !== 'cabinet') return; // a filler, side panel or toe kick has no catalog cabinets
    const catalogId = $('catalog').value;
    const category = $('category').value;
    state.cabinets = [];

    if (catalogId) {
      try {
        const res = await call('get_cabinets', { catalog_id: catalogId, cabinet_category: category });
        state.cabinets = (res.ok && res.data.cabinets) || [];
      } catch (error) {
        setStatus('error', error.message);
      }
    }

    const grouped = groupCabinets(state.cabinets);
    fillSelect($('cabinet'), grouped, {
      placeholder: state.cabinets.length ? null : 'No cabinets in this category'
    });
    $('cabinet').value = selectId && state.cabinets.some((c) => c.id === selectId)
      ? selectId
      : (grouped[0] ? grouped[0].id : '');

    if (!keepValues) applyCabinetDefaults();
    else { fillWidthPreset((currentCabinet() || {}).widths); fillApplianceChoices(currentCabinet()); syncZoneField(); }
    drawPreview();
    lockActions();
    renderGallery();
  }

  // ---- the cabinet gallery (see gallery.js): every cabinet of the category as a picture, in the order and with the names of the Cabinet list ----------------------------
  const GALLERY_KEY = 'ec.gallery';
  const gallery = { view: '3d', size: 'medium', min: false, shapes: {}, loading: '', query: '', picked: null }; // (picked: the cabinet that is on its way to the model)

  function loadGalleryPrefs() {
    try {
      const saved = JSON.parse(localStorage.getItem(GALLERY_KEY) || '{}');
      if (['2d', '3d'].includes(saved.view)) gallery.view = saved.view;
      if (['small', 'medium', 'big'].includes(saved.size)) gallery.size = saved.size;
      gallery.min = saved.min === true;
    } catch (_) { /* the usual look */ }
  }

  function saveGalleryPrefs() {
    try { localStorage.setItem(GALLERY_KEY, JSON.stringify({ view: gallery.view, size: gallery.size, min: gallery.min })); } catch (_) { /* not remembered */ }
  }

  function syncGalleryControls() {
    $('gallery').classList.toggle('min', gallery.min);
    $('galleryToggle').setAttribute('aria-expanded', String(!gallery.min));
    $('galleryGrid').dataset.size = gallery.size;
    document.querySelectorAll('[data-gallery-view]').forEach((b) => b.classList.toggle('on', b.dataset.galleryView === gallery.view));
    document.querySelectorAll('[data-gallery-size]').forEach((b) => b.classList.toggle('on', b.dataset.gallerySize === gallery.size));
  }

  // The pictures of the category in the list (fetched once per catalog and category).
  async function galleryShapes() {
    if (!$('catalog').value || !$('category').value) return {};
    const key = `${$('catalog').value}|${$('category').value}`;
    if (!gallery.shapes[key]) {
      gallery.loading = key;
      try {
        const res = await call('get_cabinet_shapes', { catalog_id: $('catalog').value, cabinet_category: $('category').value });
        if (res.ok && res.data && res.data.shapes) gallery.shapes[key] = res.data.shapes;
      } catch (error) { setStatus('error', error.message); }
      if (gallery.loading === key) gallery.loading = '';
    }
    return gallery.shapes[key] || {};
  }

  async function renderGallery() {
    const box = $('gallery');
    if (!box || !window.EC_GALLERY) return;
    syncGalleryControls();
    if (categoryKind() !== 'cabinet') { renderExtras(); return; } // (a filler, a side panel, a toe kick ...: the extras are what the gallery shows)
    $('galleryHint').textContent = GALLERY_HINT;
    const grid = $('galleryGrid');
    const all = groupCabinets(state.cabinets);
    const words = gallery.query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const entries = words.length ? all.filter((entry) => words.every((word) => entry.name.toLowerCase().includes(word))) : all; // (the search: every word is in the name)
    $('galleryCount').textContent = all.length ? (words.length ? `(${entries.length} of ${all.length})` : `(${all.length})`) : '';
    if (gallery.min) return; // (nothing is drawn while it is minimised: it is drawn when it opens)
    const shapes = await galleryShapes();
    const current = groupCabinets(state.cabinets); // (the list may have changed while the pictures came)
    if (current.length !== all.length || (current[0] && all[0] && current[0].id !== all[0].id)) return;
    grid.textContent = '';
    if (!entries.length) {
      const none = document.createElement('div');
      none.className = 'gallery-empty';
      none.textContent = all.length ? 'No cabinet has that name' : 'No cabinets in this category';
      grid.append(none);
      return;
    }
    const draw = gallery.view === '2d' ? window.EC_GALLERY.svg2d : window.EC_GALLERY.svg3d;
    entries.forEach((entry) => {
      const card = document.createElement('div');
      card.className = 'gcard';
      card.dataset.id = entry.id;
      card.tabIndex = 0;
      card.setAttribute('role', 'button');
      const shape = shapes[entry.id];
      const picture = document.createElement('div');
      picture.innerHTML = shape ? draw(shape) : '';
      const name = document.createElement('div');
      name.className = 'gname';
      name.textContent = entry.name;
      name.title = entry.name;
      const size = document.createElement('div');
      size.className = 'gsize';
      if (shape) size.textContent = `${fmtU(shape.w)} × ${fmtU(shape.d)} × ${fmtU(shape.h)} ${unitInfo().label}`;
      card.append(picture.firstChild || document.createElement('span'), name, size);
      grid.append(card);
    });
    markGallery();
  }

  // Nothing follows the cursor any more: no card is marked, and the card that was clicked does not keep the keyboard focus (its outline looks marked too).
  function clearPicked() {
    gallery.picked = null;
    if (document.activeElement && document.activeElement.classList && document.activeElement.classList.contains('gcard')) document.activeElement.blur();
    markGallery();
  }

  function markGallery() {
    const grid = $('galleryGrid');
    if (!grid) return;
    const current = categoryKind() === 'cabinet' ? gallery.picked : $('category').value; // (a cabinet is marked while it follows the cursor; an extra while it is the Category)
    grid.querySelectorAll('.gcard').forEach((card) => card.classList.toggle('on', card.dataset.id === current));
  }

  const GALLERY_HINT = 'Click a cabinet: it is chosen and follows the cursor; click in the model where it goes. Drag the gallery up or down to scroll.';
  const EXTRAS_HINT = 'Click one to choose it: its settings open below. Then press Insert (or select the item in the model to change it).';

  // The gallery of the extras: a filler, a side panel, a toe kick, a wall bottom panel, a panel and a ceiling filler, each as a picture. A click chooses it in the Category list.
  function renderExtras() {
    const grid = $('galleryGrid');
    const words = gallery.query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    const all = [...$('category').options].filter((option) => PART_CATEGORIES.includes(option.value)).map((option) => ({ id: option.value, name: option.text }));
    const entries = words.length ? all.filter((entry) => words.every((word) => entry.name.toLowerCase().includes(word))) : all;
    $('galleryCount').textContent = all.length ? (words.length ? `(${entries.length} of ${all.length})` : `(${all.length})`) : '';
    $('galleryHint').textContent = EXTRAS_HINT;
    if (gallery.min) return;
    grid.textContent = '';
    if (!entries.length) {
      const none = document.createElement('div');
      none.className = 'gallery-empty';
      none.textContent = all.length ? 'Nothing has that name' : 'Choose a model to see its extras';
      grid.append(none);
      return;
    }
    const draw = gallery.view === '2d' ? window.EC_GALLERY.svg2d : window.EC_GALLERY.svg3d;
    entries.forEach((entry) => {
      const shape = window.EC_GALLERY.extraShape(entry.id);
      const card = document.createElement('div');
      card.className = 'gcard';
      card.dataset.id = entry.id;
      card.tabIndex = 0;
      card.setAttribute('role', 'button');
      const picture = document.createElement('div');
      picture.innerHTML = shape ? draw(shape) : '';
      const name = document.createElement('div');
      name.className = 'gname';
      name.textContent = entry.name;
      const note = document.createElement('div');
      note.className = 'gsize gnote';
      note.textContent = window.EC_GALLERY.EXTRA_NOTES[entry.id] || '';
      card.append(picture.firstChild || document.createElement('span'), name, note);
      grid.append(card);
    });
    markGallery();
  }

  // A click on an extra: it is chosen in the Category list, as if it was picked there.
  function chooseExtra(id) {
    holdPanel();
    setSelect('category', id);
    $('category').dispatchEvent(new Event('change', { bubbles: true }));
  }

  // Picking a cabinet changes the fields above the gallery (their heights), and the panel may then scroll a selected item into view. Nothing of that must move the
  // panel under the pointer: the browser's own scroll anchoring keeps the gallery where it is when the fields above it change (it needs no help from here, and a
  // script that moves the scroll position as well fights the panel's smooth scrolling), and for a few seconds the panel is kept from scrolling to a section by itself.
  const holdPanel = () => { state.noFocusUntil = Date.now() + 4000; };

  // A click on a cabinet of the gallery: the cabinet is chosen (without changing the cabinet that is selected in the model) and the tool that puts it where you click
  // starts: it follows the cursor in the model and is put down by the next click there.
  async function placeFromGallery(id) {
    if (!state.cabinets.some((c) => c.id === id)) return;
    state.galleryPick = true;
    holdPanel();
    try {
      $('cabinet').value = id;
      $('cabinet').dispatchEvent(new Event('change', { bubbles: true }));
    } finally {
      state.galleryPick = false;
    }
    // While the cabinet follows the cursor and is put down, what is selected in the model changes (the new cabinet, its toe kick, the cabinet again): the panel must
    // not follow that with its cards and lists (they would jump up and down), so it leaves them alone until the placing is over (the event place_end).
    state.noFocusUntil = Date.now() + 600000;
    state.lastResult = null;
    gallery.picked = id;
    markGallery();
    await runAction('insert_at_point', { extra: { place_toe_kick: { ...collectToeKick(), toe_kick_piece_length: mmv('width'), toe_kick_pieces: '1', toe_kick_cover_row: false } } }); // (the cabinet is put down with a toe kick as long as it is wide)
    if (!state.lastResult || !state.lastResult.ok) { state.noFocusUntil = 0; gallery.picked = null; markGallery(); } // (the placing did not start: nothing is to be left alone)
  }

  function wireGallery() {
    if (!$('gallery')) return;
    // Esc in the panel drops the cabinet that follows the cursor (in the model SketchUp sees Esc itself: the placing tool tells the panel when it ends)
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape' || !gallery.picked) return;
      clearPicked();
      call('cancel_place').catch(() => {});
    });
    loadGalleryPrefs();
    syncGalleryControls();
    let searchTimer = null;
    $('gallerySearch').addEventListener('input', () => { // the search: the cabinets whose name has the words typed
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { gallery.query = $('gallerySearch').value; renderGallery(); }, 120);
    });
    $('gallerySearch').addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { $('gallerySearch').value = ''; gallery.query = ''; renderGallery(); }
      if (e.key === 'Enter') { const first = $('galleryGrid').querySelector('.gcard'); if (first) { if (categoryKind() === 'cabinet') placeFromGallery(first.dataset.id); else chooseExtra(first.dataset.id); } } // (the first one found)
    });
    $('galleryToggle').addEventListener('click', () => {
      gallery.min = !gallery.min;
      saveGalleryPrefs();
      renderGallery();
    });
    document.querySelectorAll('[data-gallery-view]').forEach((b) => b.addEventListener('click', () => { gallery.view = b.dataset.galleryView; saveGalleryPrefs(); renderGallery(); }));
    document.querySelectorAll('[data-gallery-size]').forEach((b) => b.addEventListener('click', () => { gallery.size = b.dataset.gallerySize; saveGalleryPrefs(); renderGallery(); }));

    // The gallery scrolls inside itself, with the mouse wheel and with the grab hand: press anywhere in it and drag, and the list moves with the hand (when the
    // list is short enough not to scroll, the panel does). A click on a cabinet chooses it and starts the placing (see placeFromGallery).
    const grid = $('galleryGrid');
    let drag = null;
    const panel = () => $('scroll');
    const scroller = () => (grid.scrollHeight > grid.clientHeight + 1 ? grid : panel()); // (the list scrolls inside the gallery; the panel only when it has nothing to scroll)
    const finish = () => {
      if (drag && drag.card) drag.card.classList.remove('dragging');
      document.body.classList.remove('gallery-dragging');
      drag = null;
    };
    grid.addEventListener('dragstart', (e) => e.preventDefault()); // (the picture is not dragged as an image)
    // The wheel scrolls the list while it can go that way; at its top or bottom the wheel goes on to the panel.
    grid.addEventListener('wheel', (e) => {
      const room = grid.scrollHeight - grid.clientHeight;
      if (room <= 1 || (e.deltaY < 0 && grid.scrollTop <= 0) || (e.deltaY > 0 && grid.scrollTop >= room - 1)) return;
      e.stopPropagation(); // (the panel's own smooth scrolling must not take it)
    }, { passive: true });
    grid.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || !e.target.closest('#galleryGrid')) return;
      const card = e.target.closest('.gcard');
      e.preventDefault(); // (no text selection and no automatic scrolling of the panel while it is dragged)
      holdPanel();
      const moving = scroller();
      drag = { id: card ? card.dataset.id : null, card, x: e.clientX, y: e.clientY, moving, from: moving.scrollTop, moved: false };
      try { (card || grid).setPointerCapture(e.pointerId); } catch (_) { /* no capture: the drag still ends when the pointer leaves */ }
    });
    grid.addEventListener('pointermove', (e) => {
      if (!drag) return;
      if (!drag.moved && Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 6) {
        drag.moved = true;
        document.body.classList.add('gallery-dragging');
      }
      if (drag.moved) drag.moving.scrollTop = drag.from - (e.clientY - drag.y); // the list moves with the hand
    });
    grid.addEventListener('pointerup', () => {
      if (!drag) return;
      const was = drag;
      finish();
      if (!was.moved && was.id) { if (categoryKind() === 'cabinet') placeFromGallery(was.id); else chooseExtra(was.id); } // a click: a cabinet follows the cursor until it is put down; an extra is chosen
    });
    grid.addEventListener('pointercancel', finish);
    grid.addEventListener('keydown', (e) => {
      const card = e.target.closest('.gcard');
      if (card && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); if (categoryKind() === 'cabinet') placeFromGallery(card.dataset.id); else chooseExtra(card.dataset.id); }
    });
  }

  // The Standard Width list: a fixed size fills the Width field; Width can still be
  // typed freely, and the list follows it (Custom when it is not a listed size).
  function fillWidthPreset(widths) {
    // A catalog cabinet can list the widths it comes in; otherwise the general list.
    const sizes = Array.isArray(widths) && widths.length ? widths : list(state.meta && state.meta.standard_widths);
    fillSelect($('widthPreset'), [{ id: 'custom', name: 'Custom' }, ...sizes.map((w) => ({ id: String(w), name: fmtLen(w) }))]);
    syncWidthPreset();
  }

  // Panel and back-panel thickness: a list of the usual boards, and the field beside
  // it for any other thickness. The list follows the field (Custom when it is not a listed size).
  const THICKNESS_SIZES = [6, 9, 12, 18];
  const THICKNESS_PAIRS = [['thicknessPreset', 'thickness'], ['backThicknessPreset', 'backThickness']];

  function fillThicknessPresets() {
    THICKNESS_PAIRS.forEach(([presetId]) => {
      fillSelect($(presetId), [{ id: 'custom', name: 'Custom' }, ...THICKNESS_SIZES.map((t) => ({ id: String(t), name: fmtLen(t) }))]);
    });
    syncThicknessPresets();
  }

  function syncThicknessPresets() {
    THICKNESS_PAIRS.forEach(([presetId, inputId]) => {
      const value = String(num(mmv(inputId)));
      const listed = [...$(presetId).options].some((o) => o.value === value);
      $(presetId).value = listed ? value : 'custom';
    });
  }

  function syncWidthPreset() {
    const value = String(num(mmv('width')));
    const listed = [...$('widthPreset').options].some((o) => o.value === value);
    $('widthPreset').value = listed ? value : 'custom';
  }

  // An oven housing shows the appliance fields; the microwave height only with a microwave.
  function isApplianceCabinet() {
    const cabinet = currentCabinet();
    return !!(cabinet && cabinet.appliances) && categoryKind() === 'cabinet';
  }

  // The cabinets whose catalog entry has a "zone_label" let the height of that zone be adjusted.
  function hasZoneField() {
    const cabinet = currentCabinet();
    return !!(cabinet && cabinet.zone_label) && categoryKind() === 'cabinet';
  }

  // The same for the drawer zone of an oven housing, the panel over a built-in oven and the doors of a built-in fridge.
  function hasCatalogField(key) {
    const cabinet = currentCabinet();
    return !!(cabinet && cabinet[key]) && categoryKind() === 'cabinet';
  }
  const hasBottomField = () => hasCatalogField('bottom_label');
  const hasTopFrontField = () => hasCatalogField('top_front_label');
  const hasFridgeField = () => hasCatalogField('fridge_label');
  const hasLowerField = () => hasCatalogField('lower');
  const hasBlindField = () => hasCatalogField('blind_label');
  const hasWardrobeField = () => hasCatalogField('wardrobe');
  const hasSplitField = () => hasCatalogField('split_label');
  const hasLiftField = () => hasCatalogField('lift_label');
  // The model without handles (a catalog with finger_pull) lets the height the doors of a base unit are reduced by be set.
  const hasFingerField = () => !!(currentCatalog() || {}).finger_pull && categoryKind() === 'cabinet' && $('category').value === 'base';
  // A unit of drawers (drawers and no doors: drawer units, a hob unit, a pull-out) has no shelves, so the field is not shown.
  const hasShelvesField = () => {
    const cabinet = currentCabinet() || {};
    return categoryKind() === 'cabinet' && !(categoryKind() === 'cabinet' && Number(cabinet.drawers) > 0 && !Number(cabinet.doors));
  };
  // Two doors one above the other (a lift-up 2 door unit or its bi-fold) can have the glass on one of them.
  const hasTwoDoors = () => categoryKind() === 'cabinet' && (!!(currentCabinet() || {}).stacked || !!(currentCabinet() || {}).bifold);
  const hasLiftTick =() => categoryKind() === 'cabinet' && !!(currentCabinet() || {}).glass && !(currentCabinet() || {}).lift_door && !(currentCabinet() || {}).bifold;
  const hasSinkField = () => hasCatalogField('sink');
  // A unit of drawers alone can have each drawer front's height set.
  function hasDrawerHeights() {
    const cabinet = currentCabinet();
    return !!(cabinet && cabinet.drawers > 0 && !cabinet.doors && !cabinet.zone && !cabinet.zone_bottom && !cabinet.lower && !cabinet.fridge && !cabinet.corner && !cabinet.freestanding) && categoryKind() === 'cabinet';
  }
  // How many drawers the unit has: what the Number of Drawers field says (1 to 6), else the catalog's number.
  function drawerCount() {
    const cabinet = currentCabinet() || {};
    if (!hasDrawerHeights()) return cabinet.drawers || 0;
    const n = Math.round(Number(String($('drawerCount').value).replace(',', '.')));
    return n >= 1 ? Math.min(n, 6) : (cabinet.drawers || 1);
  }

  function syncZoneField() {
    const cabinet = currentCabinet();
    setSoft($('zoneField'), !hasZoneField());
    if (cabinet && cabinet.zone_label) $('zoneLabel').textContent = cabinet.zone_label;
    setSoft($('bottomField'), !hasBottomField());
    if (cabinet && cabinet.bottom_label) $('bottomLabel').textContent = cabinet.bottom_label;
    setSoft($('topFrontField'), !hasTopFrontField());
    if (cabinet && cabinet.top_front_label) $('topFrontLabel').textContent = cabinet.top_front_label;
    setSoft($('fridgeField'), !hasFridgeField());
    setSoft($('liftField'), !hasFridgeField());
    if (cabinet && cabinet.fridge_label) $('fridgeLabel').textContent = cabinet.fridge_label;
    setSoft($('doorSplitField'), !hasSplitField());
    setSoft($('splitField'), !hasSplitField() || $('doorSplit').value !== 'split');
    if (cabinet && cabinet.split_label) $('splitLabel').textContent = cabinet.split_label;
    setSoft($('liftHeightField'), !hasLiftField());
    setSoft($('fingerAllGlobalField'), !(currentCatalog() || {}).finger_pull);
    setSoft($('shelvesField'), !hasShelvesField());
    setSoft($('glassDoorsField'), !hasTwoDoors());
    setSoft($('liftDoorField'), !hasLiftTick()); // (a lift-up or bi-fold unit needs no tick)
    setSoft($('fingerGapGlobalField'), !(currentCatalog() || {}).finger_pull);
    if ((currentCatalog() || {}).finger_pull && !$('fingerGapGlobal').value) setText('fingerGapGlobal', 35);
    if (cabinet && cabinet.lift_label) $('liftHeightLabel').textContent = cabinet.lift_label;
    setSoft($('sinkFields'), !hasSinkField());
    setSoft($('drawerCountField'), !hasDrawerHeights());
    setSoft($('drawerHeightsField'), !hasDrawerHeights());
    for (let i = 1; i <= 6; i += 1) setSoft($(`drawerH${i}Field`), !hasDrawerHeights() || i > drawerCount());
    const single = !!(cabinet && cabinet.sink_single);
    setSoft($('sinkBowlsField'), single);
    setSoft($('sinkTurnField'), single || !$('sinkTray').checked); // a mirror only matters for the side the drainer is on
    setSoft($('blindField'), !hasBlindField());
    setSoft($('dividersField'), !hasWardrobeField());
    setSoft($('railField'), !hasWardrobeField());
    if (cabinet && cabinet.blind_label) $('blindLabel').textContent = cabinet.blind_label;
    setSoft($('lowerField'), !hasLowerField());
    setSoft($('lowerDrawersField'), !hasLowerField() || $('lowerMode').value !== 'drawers');
    setSoft($('smallDrawerField'), !hasLowerField() || $('lowerMode').value !== 'drawer_door');
  }

  // An L-shaped corner is described by its two legs: Width and Depth are Leg 1's length and depth.
  function setLegLabels(isL) {
    $('widthLabel').textContent = isL ? 'Leg 1 Length' : 'Width';
    $('depthLabel').textContent = isL ? 'Leg 1 Depth' : 'Depth';
  }

  // The appliance choices an entry offers (a base unit with a built-in oven holds one oven only).
  const APPLIANCE_NAMES = { oven: 'One oven', double_oven: 'Two ovens', oven_micro: 'One oven and one microwave' };

  function fillApplianceChoices(cabinet) {
    const sets = cabinet && Array.isArray(cabinet.appliance_sets) && cabinet.appliance_sets.length ? cabinet.appliance_sets : Object.keys(APPLIANCE_NAMES);
    fillSelect($('applianceSet'), sets.map((id) => ({ id, name: APPLIANCE_NAMES[id] || id })));
  }

  function syncApplianceFields(show) {
    setSoft($('applianceFields'), !show);
    setSoft($('microHeightField'), $('applianceSet').value !== 'oven_micro');
    setSoft($('oven2HeightField'), $('applianceSet').value !== 'double_oven');
    $('ovenHeightLabel').textContent = $('applianceSet').value === 'double_oven' ? 'Lower Oven Height' : 'Oven Height';
  }

  function applyCabinetDefaults() {
    const cabinet = currentCabinet();
    if (!cabinet) return;
    const d = cabinet.defaults || {};
    fillWidthPreset(cabinet.widths);
    setText('width', d.width);
    syncWidthPreset();
    setText('depth', d.depth);
    setText('leg2Length', d.leg2_length || d.width);
    setText('leg2Depth', d.leg2_depth || d.depth);
    setSoft($('legFields'), cabinet.corner !== 'l_shape');
    setLegLabels(cabinet.corner === 'l_shape');
    fillApplianceChoices(cabinet);
    setSelect('applianceSet', cabinet.appliances || 'oven');
    if (cabinet.zone_label) setText('zoneHeight', cabinet.zone);
    if (cabinet.bottom_label) setText('bottomHeight', cabinet.zone_bottom);
    if (cabinet.top_front_label) setText('topFrontHeight', cabinet.top_front);
    if (cabinet.fridge_label) setText('fridgeHeight', cabinet.fridge);
    $('liftUp').checked = true;
    if (cabinet.split_label) { $('doorSplit').value = 'full'; setText('splitHeight', cabinet.split); }
    for (let i = 1; i <= 6; i += 1) setText(`drawerH${i}`, '');
    setText('drawerCount', cabinet.drawers || 1);
    // An appliance unit (a hob, a hood, a fridge) is only on view under Show appliances: it is switched on for it.
    if (cabinet.freestanding || cabinet.hob || cabinet.hood || cabinet.free_housing) $('showAppliances').checked = true;
    if (cabinet.lift_label) setText('liftHeight', cabinet.lift);
    if (cabinet.sink) {
      $('sinkBowls').value = String(cabinet.sink_bowls || 1);
      $('sinkTray').checked = cabinet.sink_tray === true;
      $('sinkMirror').checked = false;
    }
    if (cabinet.blind_label) setText('blindWidth', cabinet.blind);
    if (cabinet.wardrobe) { setText('dividers', cabinet.dividers || 0); $('wardrobeRail').checked = cabinet.rail === true; }
    if (cabinet.lower) {
      setSelect('lowerMode', 'drawers');
      setText('lowerDrawers', cabinet.drawers || 2);
      setText('smallDrawer', 180);
    }
    syncZoneField();
    setText('ovenHeight', 595);
    setText('ovenHeight2', 595);
    setText('microHeight', 380);
    syncApplianceFields(!!cabinet.appliances);
    setText('height', d.height);
    setText('shelves', cabinet.shelves === undefined ? 0 : cabinet.shelves);
  }

  // The Cabinet Category decides which fields the Cabinet section shows: the
  // cabinet's own (cabinet type, size, shelves, gap) for every real category, or
  // the Filler / Side Panel fields when one of those is chosen. Every section (and
  // the front-view picture above) always stays where it is: Catalog, Handle,
  // Material, Toe Kick, Door Opening and Visibility never disappear. A wall unit
  // hangs at height 0, so the toe-kick height does not raise it.
  function updateCategoryUi() {
    const kind = categoryKind();
    document.querySelectorAll('.cabinet-only').forEach((el) => { setSoft(el, kind !== 'cabinet'); });
    document.querySelectorAll('.cabinet-only-btn').forEach((el) => { el.hidden = kind !== 'cabinet'; });
    document.querySelectorAll('.not-end-panel').forEach((el) => { el.hidden = kind === 'end_panel'; }); // (the side panel has its Customize below its Face)
    // The toe-kick height is shared: it raises cabinets and is a toe kick's height.
    document.querySelectorAll('.cabinet-or-toe').forEach((el) => { setSoft(el, kind !== 'toe_kick'); });
    setSoft($('sub-filler'), kind !== 'filler');
    setSoft($('sub-end-panel'), kind !== 'end_panel');
    setSoft($('sub-toe-kick'), kind !== 'toe_kick');
    setSoft($('sub-wall-bottom'), kind !== 'wall_bottom');
    setSoft($('sub-panel'), kind !== 'panel');
    setSoft($('sub-ceiling-filler'), kind !== 'ceiling_filler');
    syncPanelUi();
    setSoft($('toeNote'), true);
    setSoft($('legFields'), !(kind === 'cabinet' && (currentCabinet() || {}).corner === 'l_shape'));
    setLegLabels(kind === 'cabinet' && (currentCabinet() || {}).corner === 'l_shape');
    syncApplianceFields(isApplianceCabinet());
    syncZoneField();
  }

  async function loadCabinet(params) {
    setBadge(params.cabinet_name || params.cabinet_id || null);
    followCabinet({ height: params.height, front: params.envelope_depth, top: params.cabinet_category === 'wall' ? params.top_z - params.base_z : params.top_z });
    setSelect('catalog', resolveCatalogId(params.catalog_id));
    setSelect('frontDesign', params.front_design || 'flat'); // the design of the selected cabinet's fronts
    setSelect('glassDoor', params.glass_design || ''); // and its glass door
    setSelect('glassDoors', params.glass_doors || 'all'); // (on which of two doors)
    syncZoneField(); // (a glass design brings the Glass field)
    applyCatalogFeatures();
    setSelect('category', String(params.cabinet_type || '').startsWith('wall_loft') ? 'loft' : params.cabinet_category); // (a loft unit is a wall unit of its own list)
    updateCategoryUi();
    await refreshCabinets({ selectId: params.cabinet_type, keepValues: true });
    applyParams(params);
    syncUnitSizeFields(params);
  }

  // The size of a selected unit shows in the Unit Sizes of the Settings, in the block of its kind (base, wall, tall or loft).
  function syncUnitSizeFields(p) {
    const kind = String(p.cabinet_type || '').startsWith('wall_loft') ? 'loft' : p.cabinet_category;
    const ids = { base: ['sizeBaseW', 'sizeBaseD', 'sizeBaseH'], wall: ['sizeWallW', 'sizeWallD', 'sizeWallH'], tall: ['sizeTallW', 'sizeTallD', 'sizeTallH'], loft: ['sizeLoftW', 'sizeLoftD', 'sizeLoftH'] }[kind];
    if (!ids) return;

    setText(ids[0], p.width);
    setText(ids[1], p.depth);
    setText(ids[2], p.height);
  }

  function setBadge(name) {
    const badge = $('selectionBadge');
    badge.textContent = name || 'Nothing selected';
    badge.classList.toggle('active', !!name);
  }

  /* ---------------------------------------------------------------------- *
   * Live front-view preview
   * ---------------------------------------------------------------------- */

  const VBW = 240;
  const VBH = 176;

  // Draws whatever the Cabinet Category is: the cabinet itself, or the filler, end
  // panel or toe kick (shown against the cabinet). It is redrawn on every change
  // to any field, so the picture is always what the model is being given.
  function drawPreview() {
    if (!$('preview')) return; // the display area is not in the panel any more
    const kind = categoryKind();
    if (kind === 'cabinet') drawCabinetPreview();
    else drawExtraPreview(kind);
  }

  const numOr = (value, fallback) => (Number.isFinite(num(value)) ? num(value) : fallback);

  const EDGE_PROFILES = ['edge_pull', 'cup']; // handles that sit on the top (or bottom) edge of a front, always along it

  // The chosen handle, or null when there is none. Lengths in millimetres.
  function handleSpec() {
    const bundle = currentBundle();
    const length = num($('handleLength').value);
    if (!bundle || !(length > 0)) return null;
    const knob = bundle.profile === 'knob';
    const edge = EDGE_PROFILES.includes(bundle.profile);
    return {
      knob,
      length,
      horizontal: edge || (!knob && $('handleOrientation').value === 'horizontal'),
      position: $('handlePosition').value || 'auto',
      category: catId(),
      middle: edge || (!knob && $('handleOrientation').value === 'horizontal' && $('handleHPlace').value === 'middle'),
      side: numOr(mmv('handleSide'), 0),
      vertical: numOr(mmv('handleVert'), 0),
      customX: numOr(mmv('handleCustomX'), 50),
      customZ: numOr(mmv('handleCustomZ'), 100)
    };
  }

  const HANDLE_SECTION_MM = 10; // a bar's cross-section, as in Defaults::HANDLE_SECTION

  // Where the handle's centre goes on a door and how big it is, in millimetres
  // measured from the door's left edge and bottom (the same rules as
  // HandleManager.placement). `freeEdgeHigh`: the hinge is on the left.
  const TALL_HANDLE_HEIGHT_MM = 1050; // as in Defaults::TALL_HANDLE_HEIGHT

  // doorZ is the height of the door's bottom edge above the floor. By unit type: a
  // base unit's handle is near the top of its door, a wall unit's near the bottom,
  // and a tall unit's at hand height. A horizontal handle can instead sit in the
  // middle of the door.
  function handleGeometry(spec, doorW, doorH, freeEdgeHigh, doorZ = 0) {
    const halfAlong = spec.length / 2;
    const halfAcross = spec.knob ? halfAlong : HANDLE_SECTION_MM / 2;
    const [halfU, halfV] = spec.horizontal ? [halfAlong, halfAcross] : [halfAcross, halfAlong];
    const place = spec.category === 'wall' ? 'bottom' : spec.category === 'tall' ? 'hand' : 'top';
    const u = spec.middle ? doorW / 2 : freeEdgeHigh ? doorW - spec.side - halfU : spec.side + halfU;
    let v;
    if (place === 'top') v = doorH - spec.vertical - halfV;
    else if (place === 'bottom') v = spec.vertical + halfV;
    else v = Math.min(Math.max(TALL_HANDLE_HEIGHT_MM - doorZ, halfV), Math.max(doorH - halfV, halfV));
    return { u, v, halfU, halfV };
  }

  function drawCabinetPreview() {
    const svg = $('preview');
    const caption = $('previewCaption');

    const W = num(mmv('width'));
    const H = num(mmv('height'));
    const D = num(mmv('depth'));
    if (!(W > 0 && H > 0)) {
      svg.innerHTML = '';
      caption.textContent = 'Enter width and height to see the front view.';
      return;
    }

    const isWall = catId() === 'wall';
    let toe = isWall ? 0 : num(mmv('toeHeight'));
    if (!Number.isFinite(toe) || toe < 0) toe = 0;

    const cabinet = currentCabinet();
    const doors = cabinet ? (cabinet.doors | 0) : 0;
    const shelves = hasShelvesField() ? Math.min(20, Math.max(0, parseInt($('shelves').value, 10) || 0)) : 0;
    const hingeOnLeft = $('direction').value !== 'right';
    const showSwing = $('showDoorSymbol').checked;
    // The Visibility ticks show in the picture too: an unticked part is faded.
    const showDoors = $('visDoor').checked;
    const showToe = $('visToe').checked;
    const carcassClass = $('visCarcass').checked ? 'pv-body' : 'pv-body pv-off';
    const handle = handleSpec();
    const revealMm = numOr(mmv('doorReveal'), 2);
    const gapMm = numOr(mmv('doorGap'), 1.5);

    const padX = 26;
    const top = 12;
    const bottom = 24;
    const s = Math.min((VBW - 2 * padX) / W, (VBH - top - bottom) / (H + toe));
    const bw = W * s;
    const bh = H * s;
    const th = toe * s;
    const x0 = (VBW - bw) / 2;
    const floorY = VBH - bottom;
    const bodyBottom = floorY - th;
    const bodyTop = bodyBottom - bh;

    const out = [];
    out.push(`<line class="pv-floor" x1="${x0 - 14}" y1="${floorY}" x2="${x0 + bw + 14}" y2="${floorY}"/>`);

    if (th > 0) {
      const inset = Math.min(8, bw * 0.05);
      const toeW = bw - 2 * inset;
      out.push(`<rect class="${showToe ? 'pv-toe' : 'pv-toe pv-off'}" x="${x0 + inset}" y="${bodyBottom}" width="${toeW}" height="${th}"/>`);
    }
    out.push(`<rect class="${carcassClass}" x="${x0}" y="${bodyTop}" width="${bw}" height="${bh}"/>`);

    for (let i = 1; i <= shelves; i += 1) {
      const y = bodyTop + (bh * i) / (shelves + 1);
      out.push(`<line class="pv-shelf" x1="${x0}" y1="${y}" x2="${x0 + bw}" y2="${y}"/>`);
    }

    if (doors > 0 && showDoors) {
      // Schematic, not to scale: fixed insets keep the door outline readable.
      const reveal = 3.5;
      const gap = 3;
      const doorW = (bw - 2 * reveal - (doors - 1) * gap) / doors;
      const doorTop = bodyTop + reveal;
      const doorH = bh - 2 * reveal;
      // The real door size, for placing the handle at true scale on the drawn door.
      const doorWMm = (W - 2 * revealMm - (doors - 1) * gapMm) / doors;
      const doorHMm = H - 2 * revealMm;

      for (let i = 0; i < doors; i += 1) {
        const dx = x0 + reveal + i * (doorW + gap);
        // One door: hinge on the chosen side. Several doors: hinges on the outer sides.
        const left = doors === 1 ? hingeOnLeft : i < doors / 2;
        const hingeX = left ? dx : dx + doorW;
        const freeX = left ? dx + doorW : dx;
        const midY = doorTop + doorH / 2;

        out.push(`<rect class="pv-door" x="${dx}" y="${doorTop}" width="${doorW}" height="${doorH}"/>`);
        if (showSwing) {
          out.push(`<polyline class="pv-swing" points="${freeX},${doorTop} ${hingeX},${midY} ${freeX},${doorTop + doorH}"/>`);
        }
        out.push(`<circle class="pv-hinge" cx="${hingeX}" cy="${doorTop + doorH * 0.14}" r="1.5"/>`);
        out.push(`<circle class="pv-hinge" cx="${hingeX}" cy="${doorTop + doorH * 0.86}" r="1.5"/>`);

        if (handle) {
          // Hinge on the left means the free edge (where the handle goes) is the high one.
          const g = handleGeometry(handle, doorWMm, doorHMm, left, (isWall ? 0 : toe) + revealMm);
          const cx = dx + g.u * s;
          const cy = doorTop + doorH - g.v * s;
          if (handle.knob) {
            out.push(`<circle class="pv-handle" cx="${cx}" cy="${cy}" r="${Math.max(1.6, g.halfU * s)}"/>`);
          } else {
            const hw = Math.max(1.6, g.halfU * 2 * s);
            const hh = Math.max(1.6, g.halfV * 2 * s);
            out.push(`<rect class="pv-handle" x="${cx - hw / 2}" y="${cy - hh / 2}" width="${hw}" height="${hh}" rx="0.8"/>`);
          }
        }
      }
    }

    out.push(`<text class="pv-dim" x="${VBW / 2}" y="${floorY + 14}" text-anchor="middle">${fmtU(W)}</text>`);
    out.push(`<text class="pv-dim" transform="translate(${x0 + bw + 11} ${(bodyTop + bodyBottom) / 2}) rotate(-90)" text-anchor="middle">${fmtU(H)}</text>`);
    svg.innerHTML = out.join('');

    const depthText = Number.isFinite(D) ? `, D ${fmtU(D)}` : '';
    caption.textContent = `W ${fmtU(W)}${depthText}, H ${fmtU(H)} ${unitInfo().label}. Base Z ${fmtU(toe)} ${unitInfo().label}, top Z ${fmtU(toe + H)} ${unitInfo().label}.`;
  }

  // ---- filler / side panel / toe kick ------------------------------------------------
  // Front view, in millimetres: x along the row, z up from the floor. Each is drawn
  // as a solid part next to a dashed outline of the cabinet, so you can see how it
  // sits (the cabinet's own width, height and toe-kick height come from its fields).

  // Draws `parts` ({ x, z, w, h, cls, label?, joints? }) scaled to fit, on the floor.
  function drawScene(parts, captionText) {
    const svg = $('preview');
    const minX = Math.min(...parts.map((p) => p.x));
    const maxX = Math.max(...parts.map((p) => p.x + p.w));
    const maxZ = Math.max(...parts.map((p) => p.z + p.h));
    const padX = 26;
    const top = 12;
    const bottom = 24;
    const s = Math.min((VBW - 2 * padX) / (maxX - minX), (VBH - top - bottom) / maxZ);
    const x0 = (VBW - (maxX - minX) * s) / 2;
    const floorY = VBH - bottom;
    const px = (x) => x0 + (x - minX) * s;
    const py = (z) => floorY - z * s;

    const out = [`<line class="pv-floor" x1="${x0 - 14}" y1="${floorY}" x2="${x0 + (maxX - minX) * s + 14}" y2="${floorY}"/>`];
    parts.forEach((p) => {
      out.push(`<rect class="${p.cls}" x="${px(p.x)}" y="${py(p.z + p.h)}" width="${Math.max(p.w * s, 1.2)}" height="${Math.max(p.h * s, 1.2)}"/>`);
      (p.joints || []).forEach((jx) => {
        out.push(`<line class="pv-joint" x1="${px(jx)}" y1="${py(p.z + p.h)}" x2="${px(jx)}" y2="${py(p.z)}"/>`);
      });
      if (p.label) {
        out.push(`<text class="pv-dim" x="${px(p.x + p.w / 2)}" y="${floorY + 14}" text-anchor="middle">${p.label}</text>`);
      }
      if (p.heightLabel) {
        out.push(`<text class="pv-dim" transform="translate(${px(p.x + p.w) + 9} ${py(p.z + p.h / 2)}) rotate(-90)" text-anchor="middle">${p.heightLabel}</text>`);
      }
    });
    svg.innerHTML = out.join('');
    $('previewCaption').textContent = captionText;
  }

  // The cabinet the part goes with, as a dashed outline.
  function ghostCabinet(lift) {
    const w = numOr(mmv('width'), 600);
    const h = numOr(mmv('height'), 780);
    return { x: 0, z: lift, w, h, cls: 'pv-ghost' };
  }

  function drawExtraPreview(kind) {
    const svg = $('preview');
    if (kind === 'ceiling_filler') {
      svg.innerHTML = '';
      $('previewCaption').textContent = `Ceiling filler ${fmtU(num(mmv('cfHeight')))} ${unitInfo().label} high over every loft.`;
      return;
    }
    if (kind === 'panel') {
      svg.innerHTML = '';
      $('previewCaption').textContent = `Panel ${fmtU(num(mmv('panelWidth')))} × ${fmtU(num(mmv('panelLength')))} ${unitInfo().label}, ${$('panelOrientation').value}.`;
      return;
    }
    const lift = Math.max(0, numOr(mmv('toeHeight'), 100));
    const cabinet = ghostCabinet(lift);

    if (kind === 'filler') {
      const w = num(mmv('fillerWidth'));
      const t = num(mmv('fillerThickness'));
      const h = num(mmv('fillerHeight'));
      if (!(w > 0 && h > 0)) {
        svg.innerHTML = '';
        $('previewCaption').textContent = 'Enter the filler width and height to see it.';
        return;
      }
      // Beside the cabinet, on the same base height (the wall side is worked out when it is inserted).
      const filler = { x: cabinet.w, z: lift, w, h, cls: 'pv-part', label: fmtU(w), heightLabel: fmtU(h) };
      drawScene([cabinet, filler], `Filler ${fmtU(w)} × ${fmtU(h)} ${unitInfo().label}${Number.isFinite(t) ? `, ${fmtU(t)} thick` : ''}, flush with the door, base Z ${fmtU(lift)} ${unitInfo().label}.`);
    } else if (kind === 'end_panel') {
      const d = num(mmv('epDepth'));
      const t = num(mmv('epThickness'));
      const h = num(mmv('epHeight'));
      if (!(t > 0 && h > 0)) {
        svg.innerHTML = '';
        $('previewCaption').textContent = 'Enter the side panel thickness and height to see it.';
        return;
      }
      const left = $('epSide').value !== 'right';
      const panel = { x: left ? -t : cabinet.w, z: 0, w: t, h, cls: 'pv-part', label: fmtU(t), heightLabel: fmtU(h) };
      drawScene([cabinet, panel], `Side panel on the ${left ? 'left' : 'right'}: depth ${Number.isFinite(d) ? fmtU(d) : '?'}, thickness ${fmtU(t)}, height ${fmtU(h)} ${unitInfo().label}.`);
    } else {
      const len = num(mmv('pieceLength'));
      const count = Math.floor(num($('pieceCount').value));
      const h = num(mmv('toeHeight'));
      const t = num(mmv('toeThickness'));
      const recess = num(mmv('toeRecess'));
      if (!(len > 0 && count > 0 && h > 0)) {
        svg.innerHTML = '';
        $('previewCaption').textContent = 'Enter the piece length, number of pieces and height to see the toe kick.';
        return;
      }
      const total = len * count;
      const joints = [];
      for (let i = 1; i < Math.min(count, 60); i += 1) joints.push(len * i);
      const kick = { x: 0, z: 0, w: total, h, cls: 'pv-toe', joints, label: fmtU(total), heightLabel: fmtU(h) };
      // The cabinet stands on it.
      drawScene([{ ...cabinet, z: h }, kick],
        `Toe kick: ${count} × ${fmtU(len)} = ${fmtU(total)} ${unitInfo().label} long, ${fmtU(h)} high${Number.isFinite(t) ? `, ${fmtU(t)} thick` : ''}${Number.isFinite(recess) ? `, recess ${fmtU(recess)} ${unitInfo().label}` : ''}.`);
    }
  }

  /* ---------------------------------------------------------------------- *
   * Status + validation display
   * ---------------------------------------------------------------------- */

  function setStatus(kind, message, details = []) {
    const box = $('status');
    box.className = `status ${kind}`;
    box.textContent = '';
    box.hidden = !message;
    if (!message) return;

const close = document.createElement('button'); // a cross to put the message away
close.type = 'button';
close.className = 'status-close';
close.textContent = '\u00d7';
close.title = 'Close';
close.setAttribute('aria-label', 'Close the message');
close.addEventListener('click', () => { box.hidden = true; });
box.append(close);
box.append(document.createTextNode(message));
if (details.length) {
      const list = document.createElement('ul');
      details.forEach((text) => {
        const item = document.createElement('li');
        item.textContent = text;
        list.append(item);
      });
      box.append(list);
    }
  }

  function clearInvalid() {
    document.querySelectorAll('.field.invalid').forEach((f) => f.classList.remove('invalid'));
  }

  // `focus: false` (a live update) only marks the fields: it must not scroll the
  // panel or take the cursor away from what the user is typing.
  function markInvalid(errors, kind, { focus = true } = {}) {
    const map = kind === 'filler' ? FILLER_FIELD_TO_ELEMENT
      : kind === 'end_panel' ? END_PANEL_FIELD_TO_ELEMENT : FIELD_TO_ELEMENT;
    let first = null;
    (errors || []).forEach((error) => {
      const id = map[error.field];
      const el = id ? $(id) : null;
      if (!el) return;
      const field = el.closest('.field');
      if (field) field.classList.add('invalid');
      const card = el.closest('.card');
      if (focus && card && card.classList.contains('collapsed')) toggleCard(card, true);
      if (!first) first = el;
    });
    if (focus && first && !first.disabled) {
      first.scrollIntoView({ block: 'center', behavior: 'smooth' });
      first.focus({ preventScroll: true });
    }
  }

  /* ---------------------------------------------------------------------- *
   * Soft motion: things slide and fade instead of snapping
   * ---------------------------------------------------------------------- */

  const SOFT_MS = 420;
  const SOFT_EASING = 'cubic-bezier(0.45, 0, 0.25, 1)';

  // Shows or hides a block (a group of fields) by easing its height and opacity.
  // Before the panel has finished building, or where the browser cannot animate,
  // it just shows / hides.
  // A variation brings its own tall units (fridge, freezer, oven, storage): the fridge and oven answers are then not used.
  // The sink and the hob can be put on a wall of the layout only: the walls it does not have cannot be chosen.
  function syncWallChoices() {
    const layout = $('kitchenLayout').value;
    ['kitchenSinkWall', 'kitchenHobWall', 'kitchenIslandWall'].forEach((id) => {
      const select = $(id);
      Array.from(select.options).forEach((option) => {
        option.disabled = (option.value === 'b' && layout === 'straight') || (option.value === 'c' && layout !== 'u');
      });
      if (select.selectedOptions[0] && select.selectedOptions[0].disabled) select.value = id === 'kitchenIslandWall' ? 'a' : '';
    });
  }

  function syncVariation() {
    const own = !!$('kitchenVariation').value;
    setSoft($('kitchenFridge').closest('.field'), own);
    setSoft($('kitchenOven').closest('.check'), own);
  }

  function setSoft(el, hide) {
    if (!el) return;
    const wanted = el.softHide === undefined ? el.hidden : el.softHide;
    if (wanted === hide) return;
    el.softHide = hide;
    if (el.softAnimation) {
      el.softAnimation.cancel();
      el.softAnimation = null;
      el.style.overflow = '';
    }
    if (!state.animate || typeof el.animate !== 'function') {
      el.hidden = hide;
      return;
    }

    if (!hide) el.hidden = false;
    const style = getComputedStyle(el);
    const open = {
      height: `${el.offsetHeight}px`, opacity: 1,
      marginTop: style.marginTop, marginBottom: style.marginBottom,
      paddingTop: style.paddingTop, paddingBottom: style.paddingBottom
    };
    const shut = { height: '0px', opacity: 0, marginTop: '0px', marginBottom: '0px', paddingTop: '0px', paddingBottom: '0px' };
    el.style.overflow = 'hidden';
    el.softAnimation = el.animate(hide ? [open, shut] : [shut, open], { duration: SOFT_MS, easing: SOFT_EASING });
    el.softAnimation.onfinish = () => {
      el.softAnimation = null;
      el.style.overflow = '';
      if (hide) el.hidden = true;
    };
  }

  // Mouse-wheel scrolling that glides to where it is going instead of jumping.
  function enableSmoothScroll(el) {
    let target = el.scrollTop;
    let frame = null;
    const step = () => {
      const distance = target - el.scrollTop;
      if (Math.abs(distance) < 0.5) {
        el.scrollTop = target;
        frame = null;
        return;
      }
      el.scrollTop += distance * 0.13;
      frame = requestAnimationFrame(step);
    };
    el.addEventListener('wheel', (event) => {
      if (event.ctrlKey || event.deltaY === 0) return;
      event.preventDefault();
      const pixels = event.deltaMode === 1 ? event.deltaY * 32 : event.deltaMode === 2 ? event.deltaY * el.clientHeight : event.deltaY;
      const start = frame ? target : el.scrollTop;
      target = Math.max(0, Math.min(el.scrollHeight - el.clientHeight, start + pixels));
      if (!frame) frame = requestAnimationFrame(step);
    }, { passive: false });
    // Dragging the scroll bar, the keyboard or scrollIntoView move it too: follow.
    el.addEventListener('scroll', () => { if (!frame) target = el.scrollTop; });
  }
  // Like an accordion: opening a section closes whichever other one is open.
  function toggleCard(card, open) {
    const collapsed = open === undefined ? !card.classList.contains('collapsed') : !open;
    if (!collapsed) {
      document.querySelectorAll('.card').forEach((other) => {
        if (other !== card && other.querySelector('.card-head') && !other.classList.contains('collapsed')) toggleCard(other, false);
      });
    }
    card.querySelector('.card-head').setAttribute('aria-expanded', String(!collapsed));

    const body = card.querySelector('.card-body');
    const inner = body && body.firstElementChild;
    if (card.classList.contains('collapsed') === collapsed) return;
    if (!body || !inner || !state.animate) {
      card.classList.toggle('collapsed', collapsed);
      if (body) body.style.height = '';
      return;
    }

    // Slide the body down (open) or up (closed) over --collapse-ms. From wherever it
    // is now, so a click in the middle of a slide just turns it round.
    clearTimeout(body.slideTimer);
    const from = body.offsetHeight;
    body.style.height = `${from}px`;
    void body.offsetHeight; // let the browser take that height before it changes
    if (collapsed) {
      card.classList.add('collapsed');
      body.style.height = '0px';
    } else {
      card.classList.remove('collapsed');
      body.style.height = `${inner.scrollHeight}px`;
      // Once open, the height follows the content again (fields that show or hide).
      body.slideTimer = setTimeout(() => {
        if (!card.classList.contains('collapsed')) body.style.height = '';
      }, 1000);
    }
  }

  // Each section body gets an inner box that carries the padding, so the height the
  // slide animates to is exactly the height of the content.
  function wrapCardBodies() {
    document.querySelectorAll('.card-body').forEach((body) => {
      if (body.firstElementChild && body.firstElementChild.classList.contains('card-inner')) return;
      const inner = document.createElement('div');
      inner.className = 'card-inner';
      if (body.classList.contains('checks')) {
        inner.classList.add('checks');
        body.classList.remove('checks');
      }
      while (body.firstChild) inner.appendChild(body.firstChild);
      body.appendChild(inner);
    });
  }

  /* ---------------------------------------------------------------------- *
   * The order of the sections: each can be moved up or down (the arrows, or drag the grip), and the order is remembered
   * ---------------------------------------------------------------------- */

  const CARD_ORDER_KEY = 'ec.cardOrder';
  const cardList = () => [...$('scroll').querySelectorAll(':scope > section.card')];

  function saveCardOrder() {
    try { localStorage.setItem(CARD_ORDER_KEY, JSON.stringify(cardList().map((card) => card.id))); } catch (_) { /* the order is not kept */ }
  }

  function moveCard(card, step) {
    const cards = cardList();
    const index = cards.indexOf(card) + step;
    if (index < 0 || index >= cards.length) return;
    if (step < 0) cards[index].before(card); else cards[index].after(card);
    saveCardOrder();
    card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  /* ---------------------------------------------------------------------- *
   * The cards the panel shows: Settings has a tick for each card, and what is not ticked is hidden (remembered). Settings itself is always there.
   * ---------------------------------------------------------------------- */

  const HIDDEN_CARDS_KEY = 'ec.hiddenCards';
  const cardTitle = (card) => (card.querySelector('.card-head') || {}).textContent.trim();

  function hiddenCards() {
    try {
      const saved = JSON.parse(localStorage.getItem(HIDDEN_CARDS_KEY) || '[]');
      return Array.isArray(saved) ? saved : [];
    } catch (_) { return []; }
  }

  function wireCardPrefs() {
    const box = $('cardPrefs');
    if (!box) return;
    $('cardPrefsToggle').addEventListener('click', () => { // (the list of cards opens and closes: closed to begin with)
      const open = box.hidden;
      box.hidden = !open;
      $('cardPrefsToggle').setAttribute('aria-expanded', String(open));
    });
    const hidden = new Set(hiddenCards());
    const cards = cardList().filter((card) => card.id !== 'sec-presets');
    cards.forEach((card) => {
      card.hidden = hidden.has(card.id);
      const label = document.createElement('label');
      label.className = 'check';
      const tick = document.createElement('input');
      tick.type = 'checkbox';
      tick.checked = !card.hidden;
      tick.addEventListener('change', () => {
        card.hidden = !tick.checked;
        if (tick.checked) hidden.delete(card.id); else hidden.add(card.id);
        try { localStorage.setItem(HIDDEN_CARDS_KEY, JSON.stringify([...hidden])); } catch (_) { /* not remembered */ }
      });
      const name = document.createElement('span');
      name.textContent = cardTitle(card);
      label.append(tick, name);
      box.append(label);
    });
  }

  function enableCardOrder() {
    const cards = cardList();
    let saved = [];
    try { saved = JSON.parse(localStorage.getItem(CARD_ORDER_KEY) || '[]'); } catch (_) { /* the usual order */ }
    if (Array.isArray(saved) && saved.length && cards.length) {
      const byId = new Map(cards.map((card) => [card.id, card]));
      const wanted = saved.filter((id) => byId.has(id)).map((id) => byId.get(id));
      const order = [...wanted, ...cards.filter((card) => !wanted.includes(card))];
      const marker = document.createComment('cards');
      cards[0].before(marker);
      order.forEach((card) => marker.parentNode.insertBefore(card, marker));
      marker.remove();
    }

    let dragged = null;
    const clearMarks = () => cardList().forEach((card) => card.classList.remove('drop-before', 'drop-after', 'dragging'));
    cardList().forEach((card) => {
      const tools = document.createElement('div');
      tools.className = 'card-tools';
      tools.innerHTML = '<span class="card-grip" draggable="true" title="Drag to move this section">&#8942;&#8942;</span>' +
        '<button type="button" class="card-move" data-step="-1" title="Move up" aria-label="Move up">&#9650;</button>' +
        '<button type="button" class="card-move" data-step="1" title="Move down" aria-label="Move down">&#9660;</button>';
      card.append(tools);
      tools.querySelectorAll('.card-move').forEach((button) => {
        button.addEventListener('click', (event) => { event.stopPropagation(); moveCard(card, Number(button.dataset.step)); });
      });
      const grip = tools.querySelector('.card-grip');
      grip.addEventListener('dragstart', (event) => {
        dragged = card;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', card.id);
        card.classList.add('dragging');
      });
      grip.addEventListener('dragend', () => { dragged = null; clearMarks(); });
      card.addEventListener('dragover', (event) => {
        if (!dragged || dragged === card) return;
        event.preventDefault();
        const box = card.getBoundingClientRect();
        const before = event.clientY < box.top + (box.height / 2);
        card.classList.toggle('drop-before', before);
        card.classList.toggle('drop-after', !before);
      });
      card.addEventListener('dragleave', () => card.classList.remove('drop-before', 'drop-after'));
      card.addEventListener('drop', (event) => {
        if (!dragged || dragged === card) return;
        event.preventDefault();
        if (card.classList.contains('drop-before')) card.before(dragged); else card.after(dragged);
        clearMarks();
        dragged = null;
        saveCardOrder();
      });
    });
  }

  /* ---------------------------------------------------------------------- *
   * Actions
   * ---------------------------------------------------------------------- */

  function setBusy(busy) {
    state.busy = busy;
    document.querySelectorAll('[data-action]').forEach((b) => { b.disabled = busy; });
    lockActions();
  }

  // `live` is an Update the panel sends by itself while the user edits a field.
  // It leaves the buttons alone and never steals the cursor.
  // The buttons that make something and select it (Insert of every kind, Duplicate, the fillers and panels, the worktop, the kitchen designs).
  const QUIET_SELECT = /^(insert(_filler|_end_panel|_panel|_exposed_side_panels|_toe_kick)?|duplicate|apply_ceiling_fillers|apply_wall_bottom|apply_worktop|design_kitchen|design_path_kitchen|insert_on_path)$/;

  async function runAction(action, { live = false, replace = false, extra = null } = {}) {
    if (state.busy) return;
    if (action === 'undo') clearTimeout(state.liveTimer); // a pending live edit would redo what is being undone
    clearInvalid();
    if (live) {
      state.busy = true;
      state.liveBusy = true;
    } else {
      setBusy(true);
    }
    try {
      const kind = formKind(action);
      const payload = kind ? COLLECTORS[kind]() : (CATALOG_PAYLOAD[action] ? CATALOG_PAYLOAD[action]() : {});
      if (action === 'insert_on_path') { payload.flip = $('kitchenPathFlip').checked; payload.wall_units = $('pathWallUnits').checked; } // (the tick of the Auto Kitchen card turns the cabinets round)
      if (replace) payload.replace = true; // a live update of the kitchen: the one designed before is built again
      if (extra) Object.assign(payload, extra);
      const quietly = QUIET_SELECT.test(serverAction(action)); // (this button selects what it made in the model: that must not open cards, change lists or scroll the panel)
      if (quietly) state.noFocusUntil = Date.now() + 600000;
      const res = await call(serverAction(action), payload);
      state.lastResult = res;
      if (quietly) {
        if (res.ok) { state.noFocusUntil = Date.now() + 1500; setTimeout(() => { call('get_selection').catch(() => {}); }, 1700); } // (the late selection events are left alone, then what is selected is read once, as after a placing)
        else state.noFocusUntil = 0;
      }
      if (res.ok) {
        setStatus('ok', res.message);
        if (action === 'get_cut_list') { renderCutList(res.data || {}); state.cutShown = true; }
        if (action === 'build_room' || action === 'update_room') state.roomBuilt = true;
        if (action === 'remove_room') state.roomBuilt = false;
        if (action === 'save_to_catalog' || action === 'remove_from_catalog') await catalogsChanged(res.data || {}, action);
        if (action === 'add_material' || action === 'remove_material') materialsChanged(res.data || {}, action);
        if (action === 'add_handle' || action === 'remove_handle') handlesChanged(res.data || {}, action);
        if (action === 'add_appliance' || action === 'remove_appliance') appliancesChanged(res.data || {});
        if (action === 'reset_presets') location.reload(); // starts again from the standard values
        if (action === 'design_kitchen') { state.kitchenDesigned = true; state.kitchenOnPath = false; } // from here on a change of the answers builds it again
        if (action === 'design_path_kitchen') { state.kitchenDesigned = true; state.kitchenOnPath = true; } // (along the path that was selected)
        if (action === 'design_kitchen_options') state.kitchenDesigned = false;
        if (action === 'insert' && (kind === 'filler' || kind === 'end_panel')) resetFollowing();
      } else {
        markInvalid(res.errors, kind, { focus: !live });
        setStatus('error', res.message, (res.errors || []).length > 1 ? res.errors.map((e) => e.message) : []);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      if (live) {
        state.busy = false;
        state.liveBusy = false;
      } else {
        setBusy(false);
      }
    }
  }

  /* ---------------------------------------------------------------------- *
   * Live update: editing a field changes the selected item straight away
   * ---------------------------------------------------------------------- */

  const LIVE_TYPING_DELAY_MS = 450; // wait for a pause while typing a number
  const LIVE_PICK_DELAY_MS = 60; // a list or tick box is a finished choice
  // These have their own live behaviour (Visibility ticks) or need the cabinet
  // list reloaded first (catalog / category / cabinet, see wireEvents).
  const NO_LIVE_IDS = new Set(['language', 'liveLoft', 'pathWallUnits', 'liveLoftFollow', 'liveLoftBottom', 'liveCabinet', 'liveSizes', 'resizeNeighbours', 'liveDimensions', 'liveSidePanels', 'liveToeKicks', 'liveWallBottom', 'liveWorktop', 'snapEnabled', 'followSelection', 'frontDesign', 'glassDoor', 'myFrom', 'myName', 'myCat', 'myRemove', 'units', 'rotateDegrees', 'visCarcass', 'visDoor', 'visToe', 'showAppliances', 'showOven', 'showMicro', 'showSink', 'showHob', 'showHood', 'showFreeFridge', 'visWorktop', 'visSplash', 'showDirection', 'showWallDirection', 'hideWallHandles', 'showNames', 'hideBaseHandles', 'hideTallHandles', 'hideLoftHandles', 'showDoorSymbol', 'cutGroup', 'catalog', 'category', 'cabinet']);

  // Which kind of item a field edits, so a change to the Filler fields never
  // rewrites the cabinet that happens to be selected. The toe-kick height is both:
  // it raises cabinets and is the height of a toe kick.
  const SIZE_IDS = new Set(['widthPreset', 'width', 'depth', 'height', 'leg2Length', 'leg2Depth', 'blindWidth', 'shelves', 'dividers', 'wardrobeRail']);

  function fieldKinds(el) {
    if (el.closest('#sub-filler')) return ['filler'];
    if (el.closest('#sub-end-panel')) return ['end_panel'];
    if (el.closest('#sub-panel')) return ['panel'];
    if (el.id === 'toeHeight') return ['cabinet', 'toe_kick'];
    if (el.closest('#sub-toe-kick')) return ['toe_kick'];
    return ['cabinet'];
  }

  function scheduleLive(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.liveTimer);
    state.liveTimer = setTimeout(runLive, delay);
  }

  async function runLive() {
    if (!state.selectedKind || state.liveHold) return;
    if (state.busy) {
      scheduleLive(); // something else is still running; try again shortly
      return;
    }
    await runAction('update', { live: true });
  }

  // Door gap, door reveal, panel and back panel thickness, the Handle section and the Material section
  // are settings for the whole job: editing one changes EVERY cabinet in the model when nothing is selected,
  // and only the selected cabinet when one is.
  // Only the setting that was edited is sent, so changing the door gap never
  // touches the materials of cabinets, and the other way round.
  const GLOBAL_FIELDS = {
    doorGap: ['door_gap', 'doorGap'],
    doorReveal: ['door_reveal', 'doorReveal'],
    doorDistance: ['door_distance', 'doorDistance'],
    angle: ['door_opening_angle', 'angle'],
    symbolAngle: ['symbol_angle', 'symbolAngle'],
    direction: ['door_opening_direction', 'direction'],
    glassMaterial: ['glass_material', 'glassMaterial'],
    frontRadius: ['front_radius', 'frontRadius'],
    fingerGapGlobal: ['finger_gap', 'fingerGapGlobal'],
    fingerAllGlobal: ['finger_all', 'fingerAllGlobal'],
    carcassRaise: ['carcass_raise', 'carcassRaise'],
    doorHeightAdjust: ['door_height_adjust', 'doorHeightAdjust'],
    drawerHeightAdjust: ['drawer_height_adjust', 'drawerHeightAdjust'],
    handle: ['handle_id', 'handle'],
    drawerHandle: ['drawer_handle_id', 'drawerHandle'],
    handleLength: ['handle_length', 'handleLength'],
    handleFinish: ['handle_finish', 'handleFinish'],
    handleMaterial: ['handle_material', 'handleMaterial'],
    handleOrientation: ['handle_orientation', 'handleOrientation'],
    handlePosition: ['handle_position', 'handlePosition'],
    handleHPlace: ['handle_horizontal_place', 'handleHPlace'],
    handleSide: ['handle_side_offset', 'handleSide'],
    handleVert: ['handle_vertical_offset', 'handleVert'],
    handleCustomX: ['handle_custom_x', 'handleCustomX'],
    handleCustomZ: ['handle_custom_z', 'handleCustomZ'],
    topPanel: ['top_panel_style', 'topPanel'],
    thickness: ['material_thickness', 'thickness'],
    thicknessPreset: ['material_thickness', 'thickness'],
    backThickness: ['back_thickness', 'backThickness'],
    backThicknessPreset: ['back_thickness', 'backThickness'],
    baseMaterial: ['base_material', 'baseMaterial'],
    wallMaterial: ['wall_material', 'wallMaterial'],
    tallMaterial: ['tall_material', 'tallMaterial'],
    carcassMaterial: ['carcass_material', 'carcassMaterial']
  };
  const globalDirty = new Map();

  function scheduleGlobal(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.globalTimer);
    state.globalTimer = setTimeout(runGlobal, delay);
  }

  async function runGlobal() {
    if (state.busy) {
      scheduleGlobal(); // something else is still running; try again shortly
      return;
    }
    state.busy = true;
    state.liveBusy = true; // the model events this causes must not overwrite what is being typed
    clearInvalid();
    try {
      const payload = {};
      const withHandle = !!$('handle').value;
      globalDirty.forEach((elementId, key) => {
        if (key.startsWith('handle_') && key !== 'handle_id' && !withHandle) payload[key] = ''; // no handle: nothing to set
        else if ($(elementId).type === 'checkbox') payload[key] = $(elementId).checked;
        else payload[key] = LENGTH_IDS.includes(elementId) ? mmv(elementId) : $(elementId).value;
      });
      globalDirty.clear();
      const res = await call('apply_all', payload);
      if (res.ok) {
        setStatus('ok', res.message);
      } else {
        markInvalid(res.errors, 'cabinet', { focus: false });
        setStatus('error', res.message, (res.errors || []).length > 1 ? res.errors.map((e) => e.message) : []);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  // The Toe Kick fields act on EVERY toe kick in the model, unless one is selected:
  // then they edit that one on its own (see liveEdit). Only changed fields are sent.
  const TOE_FIELDS = {
    toeHeight: ['toe_kick_height', 'toeHeight'],
    toeThickness: ['toe_kick_thickness', 'toeThickness'],
    toeRecess: ['toe_kick_recess', 'toeRecess'],
    pieceLength: ['toe_kick_piece_length', 'pieceLength'],
    pieceCount: ['toe_kick_pieces', 'pieceCount'],
    toeCover: ['toe_kick_cover_row', 'toeCover'],
    toeMaterial: ['toe_kick_material', 'toeMaterial']
  };
  const toeDirty = new Map();

  // The Filler and Side Panel fields change the ones already placed by hand when none of that kind is selected (see PartManager.update_placed).
  const PLACED_FIELDS = {
    fillerWidth: ['filler', 'width'], fillerThickness: ['filler', 'thickness'], fillerHeight: ['filler', 'height'],
    epSide: ['end_panel', 'side'], epDepth: ['end_panel', 'depth'], epThickness: ['end_panel', 'thickness'], epHeight: ['end_panel', 'height'],
    epMaterial: ['end_panel', 'material'], epFace: ['end_panel', 'face']
  };
  const placedDirty = new Map(); // kind -> Map(key -> element id)

  function schedulePlaced(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.placedTimer);
    state.placedTimer = setTimeout(runPlaced, delay);
  }

  async function runPlaced() {
    if (state.busy) {
      schedulePlaced();
      return;
    }
    state.busy = true;
    state.liveBusy = true;
    try {
      for (const [kind, edits] of [...placedDirty]) {
        const fields = {};
        edits.forEach((id, key) => { fields[key] = LENGTH_IDS.includes(id) ? mmv(id) : $(id).value; });
        placedDirty.delete(kind);
        const res = await call('update_placed', { kind, fields });
        setStatus(res.ok ? 'ok' : 'error', res.message);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  function scheduleToe(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.toeTimer);
    state.toeTimer = setTimeout(runToe, delay);
  }

  async function runToe() {
    if (state.busy) {
      scheduleToe();
      return;
    }
    state.busy = true;
    state.liveBusy = true;
    clearInvalid();
    try {
      const payload = {};
      toeDirty.forEach((elementId, key) => { payload[key] = LENGTH_IDS.includes(elementId) ? mmv(elementId) : ($(elementId).type === 'checkbox' ? $(elementId).checked : $(elementId).value); });
      toeDirty.clear();
      const res = await call('apply_toe_kicks', payload);
      if (res.ok) {
        setStatus('ok', res.message);
      } else {
        markInvalid(res.errors, 'toe_kick', { focus: false });
        setStatus('error', res.message, (res.errors || []).length > 1 ? res.errors.map((e) => e.message) : []);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  // The Worktop fields rebuild the worktops that are already there (nothing is
  // created until Apply Worktop is pressed).
  // The Room fields are live once a room is built: it is drawn again (Build Room) when a field is changed.
  function scheduleRoom(delay) {
    clearTimeout(state.roomTimer);
    state.roomTimer = setTimeout(runRoom, delay);
  }

  async function runRoom() {
    if (state.busy) {
      scheduleRoom(400);
      return;
    }
    await runAction('build_room', { live: true });
  }

  const WORKTOP_IDS = new Set(['wtThickness', 'wtFront', 'wtEnd', 'wtRound', 'wtPiece', 'wtCuts', 'wtSplash', 'wtMaterial', 'wtSplashMaterial']);

  function scheduleWorktop(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.worktopTimer);
    state.worktopTimer = setTimeout(runWorktop, delay);
  }

  // The Wall bottom panel fields apply the panels live (no need to press Apply first).
  const WALL_BOTTOM_IDS = new Set(['wbLength', 'wbThickness', 'wbSetback', 'wbLoftSetback', 'wbMaterial']);

  function scheduleWallBottom(delay = LIVE_TYPING_DELAY_MS) {
    clearTimeout(state.wallBottomTimer);
    state.wallBottomTimer = setTimeout(runWallBottom, delay);
  }

  async function runWallBottom() {
    if (state.busy) {
      scheduleWallBottom();
      return;
    }
    state.busy = true;
    state.liveBusy = true;
    clearInvalid();
    try {
      const res = await call('apply_wall_bottom', COLLECTORS.wall_bottom());
      if (res.ok) setStatus('ok', res.message);
      else setStatus('error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  async function runWorktop() {
    if (state.busy) {
      scheduleWorktop();
      return;
    }
    state.busy = true;
    state.liveBusy = true;
    clearInvalid();
    try {
      const res = await call('apply_worktop', collectWorktop());
      if (res.ok) setStatus('ok', res.message);
      else setStatus('error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  // Auto Kitchen live update: after a kitchen has been designed, changing an answer builds it again (one Undo step).
  function scheduleKitchen(delay) {
    const box = $('kitchenLive');
    if (!state.kitchenDesigned || (box && !box.checked)) return;
    clearTimeout(state.kitchenTimer);
    state.kitchenTimer = setTimeout(async () => {
      if (state.busy) { scheduleKitchen(300); return; }
      await runAction(state.kitchenOnPath ? 'design_path_kitchen' : 'design_kitchen', { live: true, replace: true });
    }, delay);
  }

  // With "Show a selected item's settings in the panel" off the panel does not take the values of the selected cabinet, so only the field that was
  // edited goes to it (the rest of the panel is not what that cabinet has): the other values of the cabinet stay as they are.
  const HELD_PARAMS = (() => {
    const map = {};
    [FIELD_TO_ELEMENT, TEXT_PARAMS, SELECT_PARAMS].forEach((table) => Object.entries(table).forEach(([key, id]) => { map[id] = key; }));
    return map;
  })();

  function scheduleHeld(el) {
    const key = HELD_PARAMS[el.id];
    if (!key || NO_LIVE_IDS.has(el.id) || !fieldKinds(el).includes('cabinet')) return;
    if (SIZE_IDS.has(el.id) && !$('liveSizes').checked) return; // sizes wait for the Update button when the switch is off
    state.heldEdits = state.heldEdits || new Map();
    state.heldEdits.set(key, el.id);
    clearTimeout(state.heldTimer);
    state.heldTimer = setTimeout(runHeld, el.tagName === 'SELECT' || el.type === 'checkbox' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
  }

  async function runHeld() {
    if (state.busy) {
      state.heldTimer = setTimeout(runHeld, 300);
      return;
    }
    const fields = {};
    (state.heldEdits || new Map()).forEach((id, key) => {
      const el = $(id);
      fields[key] = el.type === 'checkbox' ? el.checked : (LENGTH_IDS.includes(id) ? mmv(id) : el.value);
    });
    if (state.heldEdits) state.heldEdits.clear();
    if (!Object.keys(fields).length) return;
    state.busy = true;
    state.liveBusy = true;
    try {
      const res = await call('update', { fields_only: true, fields, resize_neighbours: $('resizeNeighbours').checked });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
  }

  // The Unit Sizes of the Presets (a width, depth or height for the base, wall or tall units): the selected units of that kind, or every one of them.
  const UNIT_SIZE_FIELDS = {
    sizeBaseW: ['base', 'width'], sizeBaseD: ['base', 'depth'], sizeBaseH: ['base', 'height'],
    sizeWallW: ['wall', 'width'], sizeWallD: ['wall', 'depth'], sizeWallH: ['wall', 'height'],
    sizeTallW: ['tall', 'width'], sizeTallD: ['tall', 'depth'], sizeTallH: ['tall', 'height'],
    sizeLoftW: ['loft', 'width'], sizeLoftD: ['loft', 'depth'], sizeLoftH: ['loft', 'height']
  };
  const unitSizeDirty = new Map(); // kind -> Map(key -> element id)

    // "Reset Unit Sizes": only the Unit Sizes of the Presets go back to how they began (the sizes empty, the toe kick at its standard values). No unit
  // in the model is changed by it, and the rest of the Presets is left alone.
  async function resetUnitSizes() {
    clearTimeout(state.unitSizeTimer);
    unitSizeDirty.clear();
    Object.keys(UNIT_SIZE_FIELDS).forEach((id) => { $(id).value = ''; });
    const standard = state.meta.toe_kick_defaults || {};
    setText('toeHeight', standard.toe_kick_height ?? 100);
    setText('toeThickness', standard.toe_kick_thickness ?? 18);
    setText('toeRecess', standard.toe_kick_recess ?? 50);
    setText('cfHeight', 50);
    setText('cfThickness', 18);
    setText('cfRecess', 0);
    setText('cfPiece', 2000);
    // and the size fields of Cabinets and Extras go back to the standard size of the cabinet chosen there (a filler, side panel or toe kick has none)
    const cabinet = currentCabinet();
    if (cabinet && !['filler', 'end_panel', 'toe_kick', 'wall_bottom'].includes(categoryKind())) {
      const d = cabinet.defaults || {};
      setText('width', d.width);
      syncWidthPreset();
      setText('depth', d.depth);
      setText('height', d.height);
    }
    drawPreview();
    // The units in the model go back too: the selected ones, or all of them, to the standard size of their own entry; the toe kicks and the ceiling fillers to
    // the standard values.
    try {
      const res = await call('reset_unit_sizes', { resize_neighbours: $('resizeNeighbours').checked });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
    toeDirty.set('toe_kick_height', 'toeHeight');
    toeDirty.set('toe_kick_thickness', 'toeThickness');
    toeDirty.set('toe_kick_recess', 'toeRecess');
    scheduleToe(60);
    scheduleCeilingFiller(120);
    try { await call('get_selection'); } catch (_) { /* nothing is selected */ }
  }

  function scheduleUnitSize() {
    clearTimeout(state.unitSizeTimer);
    state.unitSizeTimer = setTimeout(runUnitSize, LIVE_TYPING_DELAY_MS);
  }

  async function runUnitSize() {
    if (state.busy) {
      scheduleUnitSize();
      return;
    }
    state.busy = true;
    state.liveBusy = true;
    try {
      for (const [category, edits] of [...unitSizeDirty]) {
        const fields = {};
        edits.forEach((id, key) => { if ($(id).value.trim() !== '') fields[key] = mmv(id); });
        unitSizeDirty.delete(category);
        if (!Object.keys(fields).length) continue;
        const res = await call('set_unit_sizes', { category, fields, resize_neighbours: $('resizeNeighbours').checked });
        setStatus(res.ok ? 'ok' : 'error', res.message);
      }
    } catch (error) {
      setStatus('error', error.message);
    } finally {
      state.busy = false;
      state.liveBusy = false;
    }
    try { await call('get_selection'); } catch (_) { /* the card shows the selected unit's new size */ }
  }

  // A field was edited: update the selected item if this field belongs to it.
function liveEdit(el) {
    if (CEILING_FILLER_IDS.includes(el.id)) { // the Ceiling Filler fields are for all the ceiling fillers
      scheduleCeilingFiller(el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
      return;
    }
    if (TOE_FROM_PRESET[el.id]) { // a Toe Kick field of the Presets: it is the field of Cabinet and Extras that is edited
      const target = $(TOE_FROM_PRESET[el.id]);
      target.value = el.value;
      target.dispatchEvent(new Event('input', { bubbles: true })); // (as if it was typed there: it updates live and is remembered)
      return;
    }
    mirrorToe(el.id);
    if (UNIT_SIZE_FIELDS[el.id]) {
      const [category, key] = UNIT_SIZE_FIELDS[el.id];
      if (!unitSizeDirty.has(category)) unitSizeDirty.set(category, new Map());
      unitSizeDirty.get(category).set(key, el.id);
      scheduleUnitSize();
      return;
    }
    if (el.id === 'cutGroup') { // (the cut list that is shown is made again, grouped the other way)
      if (state.cutShown) runAction('get_cut_list');
      return;
    }
    if (el.closest('#sec-room')) { // the Room fields: a room that is built is drawn again with them
      if (state.roomBuilt) scheduleRoom(el.tagName === 'SELECT' || el.type === 'checkbox' ? 300 : 800);
      return;
    }
    if (el.closest('#sec-kitchen')) { // the Auto Kitchen answers: the kitchen designed before is built again with them
      scheduleKitchen(el.tagName === 'SELECT' || el.type === 'checkbox' ? 300 : 800);
      return;
    }
    if (WALL_BOTTOM_IDS.has(el.id)) {
      scheduleWallBottom(el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
      return;
    }
    if (WORKTOP_IDS.has(el.id)) {
      scheduleWorktop(el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
      return;
    }
    const placed = PLACED_FIELDS[el.id];
    if (placed && state.selectedKind !== placed[0]) {
      if (!placedDirty.has(placed[0])) placedDirty.set(placed[0], new Map());
      placedDirty.get(placed[0]).set(placed[1], el.id);
      schedulePlaced(el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
      return;
    }
    if (!followSelection() && state.heldKind === 'cabinet' && !state.selectedKind) { // (the panel does not follow the selection, but a cabinet is selected)
      scheduleHeld(el);
      return;
    }
    const toe = TOE_FIELDS[el.id];
    if (toe) {
      const kind = state.selectedKind;
      // Selected: edit that toe kick (or, for the shared height, that cabinet) on its own.
      const alone = kind === 'toe_kick';
      if (!alone) {
        toeDirty.set(toe[0], toe[1]);
        scheduleToe(el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
        return;
      }
    }
    // The settings of the whole job (materials, door gap, reveal, thickness, handle, carcass raise ...) are for every cabinet when
    // nothing is selected. With a cabinet selected the change is only that cabinet's (it goes through the live update below); with
    // anything else selected nothing else changes.
    // (with a filler, side panel, toe kick or worktop selected they are still the whole job's: a cabinet is the only item that takes them alone)
    // (the angle of the floor symbol is for every cabinet whatever is selected: it is how the symbols are drawn, not one cabinet's size)
    if (GLOBAL_FIELDS[el.id] && (el.id === 'symbolAngle' || !state.selectedKind || state.selectedKind !== 'cabinet')) {
      const [key, elementId] = GLOBAL_FIELDS[el.id];
      globalDirty.set(key, elementId);
      if (el.id === 'fingerGapGlobal') globalDirty.set('finger_gap_drawer', elementId); // doors and drawers alike
      // A different handle bundle brings its own lengths, finishes and positions
      // (the panel has just refilled them), so they all go along with it.
      if (el.id === 'handle') {
        Object.entries(GLOBAL_FIELDS).filter(([id]) => id.startsWith('handle')).forEach(([, [k, e]]) => globalDirty.set(k, e));
      }
      scheduleGlobal(el.id === 'symbolAngle' ? 250 : el.tagName === 'SELECT' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
      return;
    }
    if (NO_LIVE_IDS.has(el.id) || !state.selectedKind || state.liveHold) return;
    if (SIZE_IDS.has(el.id) && !$('liveSizes').checked) return; // sizes wait for the Update button when the switch is off
    if (!fieldKinds(el).includes(state.selectedKind)) return;
    scheduleLive(el.tagName === 'SELECT' || el.type === 'checkbox' ? LIVE_PICK_DELAY_MS : LIVE_TYPING_DELAY_MS);
  }

  // Carcass / Door / Toe Kick tick boxes act immediately on every cabinet in the model.
  async function applyVisibility() {
    try {
      const res = await call('visibility', {
        carcass: $('visCarcass').checked,
        door: $('visDoor').checked,
        toe_kick: $('visToe').checked,
        appliances: $('showAppliances').checked,
        oven: $('showOven').checked,
        microwave: $('showMicro').checked,
        sink: $('showSink').checked,
        hob: $('showHob').checked,
        hood: $('showHood').checked,
        free_fridge: $('showFreeFridge').checked,
        selected_only: !!state.selectedKind, // with something selected a tick is for that item alone; otherwise for all
        worktop: $('visWorktop').checked,
        backsplash: $('visSplash').checked,
        opening_direction: $('showDirection').checked, // the plan symbol on the floor
        wall_opening_direction: $('showWallDirection').checked, // a wall unit's plan symbol on the floor
        hide_wall_handles: !$('hideWallHandles').checked, // the tick says Show
        show_cabinet_names: $('showNames').checked,
        hide_base_handles: !$('hideBaseHandles').checked, // the tick says Show
        hide_tall_handles: !$('hideTallHandles').checked, // the tick says Show
        hide_loft_handles: !$('hideLoftHandles').checked, // the tick says Show
        door_symbol: $('showDoorSymbol').checked // the dashed lines on each door
      });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  /* ---------------------------------------------------------------------- *
   * Start-up
   * ---------------------------------------------------------------------- */

  function applyDefaults(d) {
    Object.entries(TEXT_PARAMS).forEach(([key, id]) => {
      if (['width', 'depth', 'height', 'shelf_count'].includes(key)) return; // come from the cabinet
      if (key in d) setText(id, d[key]);
    });
    Object.entries(SELECT_PARAMS).forEach(([key, id]) => {
      if (key in d) setSelect(id, d[key]);
    });
    setSelect('category', d.cabinet_category);
    // Both start unticked; the user ticks them when wanted.
    $('showDirection').checked = d.show_opening_direction === true;
    $('showDoorSymbol').checked = d.show_door_symbol === true;
    $('showWallDirection').checked = d.show_wall_opening_direction === true;
    $('hideWallHandles').checked = d.hide_wall_handles !== true;
    $('showNames').checked = d.show_cabinet_names === true;
    $('hideBaseHandles').checked = d.hide_base_handles !== true;
    $('hideTallHandles').checked = d.hide_tall_handles !== true;
    $('hideLoftHandles').checked = d.hide_loft_handles !== true;
    const v = d.visibility_settings || {};
    $('visCarcass').checked = v.carcass !== false;
    $('visDoor').checked = v.door !== false;
    $('visToe').checked = v.toe_kick !== false;
    $('showAppliances').checked = true; // the appliances are always shown
    $('showOven').checked = v.oven !== false;
    $('showMicro').checked = v.microwave !== false;
    $('showSink').checked = v.sink !== false;
    $('showHob').checked = v.hob !== false;
    $('showHood').checked = v.hood !== false;
    $('showFreeFridge').checked = v.free_fridge !== false;
    syncThicknessPresets();
    updateChips();
  }

  // Fills in anything an older Ruby side does not send, so the panel never fails on a missing list.
  function normaliseMeta(raw) {
    const m = Object.assign({}, raw);
    Object.keys(FALLBACK_LISTS).forEach((key) => {
      if (!list(m[key]).length) m[key] = FALLBACK_LISTS[key];
    });
    ['catalogs', 'categories', 'directions', 'warnings', 'front_designs', 'glass_designs', 'kitchen_variations', 'my_appliances'].forEach((key) => { m[key] = list(m[key]); });
    if (!list(m.standard_widths).length) m.standard_widths = [300, 350, 400, 450, 500, 600, 700, 800, 900, 1000, 1200];
    m.handle_bundles = list(m.handle_bundles).map((b) => Object.assign({ lengths: [], finishes: [], defaults: {}, profile: 'bar' }, b));
    m.materials = { panel: list(m.materials && m.materials.panel), toe_kick: list(m.materials && m.materials.toe_kick), glass: list(m.materials && m.materials.glass), mine: list(m.materials && m.materials.mine) };
    m.defaults = m.defaults || {};
    m.filler_defaults = m.filler_defaults || { width: 50, thickness: 18, height: 780, material: 'White' };
    m.end_panel_defaults = m.end_panel_defaults || { side: 'right', thickness: 18, material: 'White' };
    m.worktop_defaults = m.worktop_defaults || { worktop_thickness: 20, worktop_front: 20, worktop_end: 0, worktop_round: 5, worktop_piece: 0, worktop_cuts: '', backsplash_height: 580, material: 'White' };
    m.toe_kick_defaults = m.toe_kick_defaults || { toe_kick_height: 100, toe_kick_thickness: 18, toe_kick_material: '__door__', toe_kick_piece_length: 2000, toe_kick_pieces: 1, toe_kick_recess: 50 };
    return m;
  }

  async function buildUi() {
    const m = state.meta;
    $('appVersion').textContent = 'v' + (m.version || APP_VERSION);
    fillSelect($('units'), Object.entries(UNITS).map(([id, unit]) => ({ id, name: unit.name })));
    // The language of the panel (see i18n.js): Automatic is the language of the computer when there is a file for it.
    fillSelect($('language'), [{ id: 'auto', name: 'Automatic' }, ...window.EC_I18N.LANGUAGES.map(([id, name]) => ({ id, name }))]);
    let savedLanguage = 'auto';
    try { savedLanguage = localStorage.getItem('ec.lang') || 'auto'; } catch (_) { /* not remembered */ }
    $('language').value = savedLanguage;
    window.EC_I18N.use(savedLanguage);
    $('language').addEventListener('change', () => {
      try { localStorage.setItem('ec.lang', $('language').value); } catch (_) { /* a private window: not remembered */ }
      window.EC_I18N.use($('language').value);
    });
    $('units').value = state.unit;
    refreshUnitLabels();
    fillSelect($('topPanel'), [
      { id: '', name: 'Two separate panels' },
      { id: 'full', name: 'One full panel' }
    ]);
    fillSelect($('catalog'), m.catalogs, { placeholder: m.catalogs.length ? 'Select a model...' : 'No catalogs found' });
    fillSelect($('kitchenVariation'), [{ id: '', name: 'Standard (the fridge and oven answers above)' }, ...m.kitchen_variations]);
    fillSelect($('frontDesign'), m.front_designs.length ? m.front_designs : [{ id: 'flat', name: 'Flat (slab)' }]);
    fillSelect($('glassDoor'), [{ id: '', name: 'None' }, ...list(m.glass_designs)]);
    fillSelect($('handle'), arrangeHandles(m.handle_bundles), { placeholder: 'None' });
    fillSelect($('drawerHandle'), arrangeHandles(m.handle_bundles), { placeholder: 'Same as doors' });
    // Filler, Side Panel and Toe Kick are choices in the same list as the cabinet categories.
    applyCatalogFeatures(); // fills the Cabinet Category list with what the catalog offers
    gateUntilModel();
    fillSelect($('direction'), m.directions);
    fillWidthPreset();
    fillThicknessPresets();
    fillSelect($('handleOrientation'), m.handle_orientations);
    fillSelect($('handlePosition'), m.handle_positions);
    fillSelect($('handleHPlace'), m.handle_horizontal_places);
    fillSelect($('applianceSet'), [{ id: 'oven', name: 'One oven' }, { id: 'double_oven', name: 'Two ovens' }, { id: 'oven_micro', name: 'One oven and one microwave' }]);
    // A new cabinet starts with a horizontal handle in the middle of its doors.
    setSelect('handleOrientation', 'horizontal');
    setSelect('handleHPlace', 'middle');
    syncHandlePosition();
    fillSelect($('epSide'), m.end_panel_sides);
    setSelect('epSide', (m.end_panel_defaults || {}).side || 'right'); // (the right side to begin with)
    loadMaterials(m.materials);
    applyDefaults(m.defaults);
    $('visWorktop').checked = m.show_worktop !== false; // what the model has hidden
    $('visSplash').checked = m.show_backsplash !== false;
    applyFillerDefaults(m.filler_defaults);
    applyEndPanelDefaults(m.end_panel_defaults);
    applyToeKickDefaults(m.toe_kick_defaults);
    applyWorktopDefaults(m.worktop_defaults);
    setText('wbThickness', 18);
    setText('wbLength', 2000);
    setText('wbSetback', 20);
    setText('wbLoftSetback', 0);
    await restorePresets();
    updateCategoryUi();
    await refreshCabinets();
    Object.keys(TOE_PRESET).forEach(mirrorToe);
    renderAppliances();
    syncWallChoices();
    try { await call('get_selection'); } catch (_) { /* nothing selected, or an older Ruby side */ } // what is selected in the model opens in the panel

    if (m.version !== APP_VERSION) {
      setStatus('error', `SketchUp is still running an older version of the Ruby code (${m.version || 'unknown'}; this panel is ${APP_VERSION}). Close SketchUp completely and reopen it to finish the update.`);
    } else if (m.warnings.length) {
      setStatus('error', 'Some catalog files could not be loaded.', m.warnings);
    }
  }

  // With "Show a selected item's settings" off, a cabinet selected while no card could show it is kept; opening such a card (Presets, Handle,
  // Material, Cabinet & Extras) fills it with that cabinet, and from then on what is typed updates it live like any selected cabinet.
  function showHeld() {
    if (followSelection() || !state.heldData || state.heldKind !== 'cabinet') return;

    handleEvent('cabinet_selected', state.heldData);
  }

  function wireEvents() {
    document.querySelectorAll('.card-head').forEach((button) => {
      button.addEventListener('click', () => { toggleCard(button.closest('.card')); setTimeout(showHeld, 0); });
    });

    // Catalog / category / cabinet reload the cabinet list (and the sizes that
    // come with a cabinet) first, and only then update the selected cabinet.
    const liveAfterCabinetChange = () => {
      if (state.selectedKind === 'cabinet' && categoryKind() === 'cabinet') scheduleLive(LIVE_PICK_DELAY_MS);
    };
    $('catalog').addEventListener('change', async () => {
      // The lists are for the next Insert: the cabinet selected in the model is left alone.
      if (state.selectedKind) { state.liveHold = true; clearTimeout(state.liveTimer); }
      applyCatalogFeatures();
      updateCategoryUi();
      await refreshCabinets();
      if (categoryKind() !== 'cabinet') renderGallery();
    });
    $('category').addEventListener('change', async () => {
      // Choosing a category is for the next Insert: the cabinet selected in the model stays as it is
      // until another one is selected.
      if (state.selectedKind) { state.liveHold = true; clearTimeout(state.liveTimer); }
      updateCategoryUi();
      await refreshCabinets();
      if (categoryKind() !== 'cabinet') renderGallery();
    });
    $('applianceSet').addEventListener('change', () => syncApplianceFields(true));
    $('lowerMode').addEventListener('change', syncZoneField);
    $('doorSplit').addEventListener('change', syncZoneField);
    $('drawerCount').addEventListener('input', syncZoneField);
    $('frontDesign').addEventListener('change', applyFrontDesign);
    $('glassDoor').addEventListener('change', applyGlassDesign);
    $('glassDoor').addEventListener('change', syncZoneField); // a glass door brings the Glass field
    $('myFrom').addEventListener('change', () => { // choosing a material of the model offers its name
      const id = $('myFrom').value;
      $('myName').value = id;
    });
    $('sinkTray').addEventListener('change', syncZoneField);
    $('cabinet').addEventListener('change', () => {
      markGallery();
      // Choosing another cabinet fills the fields for the next Insert. It does not change the cabinet selected in the model (select it again,
      // or press Update, to change it) unless the tick under the list says so.
      const follow = !state.galleryPick && $('liveCabinet').checked && state.selectedKind === 'cabinet' && categoryKind() === 'cabinet';
      if (state.selectedKind && !follow) { state.liveHold = true; clearTimeout(state.liveTimer); }
      const kept = follow ? ['width', 'depth', 'height'].map((id) => [id, $(id).value]) : []; // (the selected cabinet keeps its own size: only its type changes)
      applyCabinetDefaults();
      kept.forEach(([id, value]) => { $(id).value = value; });
      drawPreview();
      lockActions();
      if (follow) { state.liveHold = false; liveAfterCabinetChange(); } // (picking from the list is a deliberate change: an earlier hold does not stop it)
    });
    wireGallery();
    $('widthPreset').addEventListener('change', () => {
      if ($('widthPreset').value !== 'custom') {
        setText('width', Number($('widthPreset').value));
        // A standard width comes with the standard depth and height of the cabinet
        // (560 deep, 780 high for a base unit).
        // (not when a cabinet is selected: its own depth and height stay, and it follows the new width live)
        if (!state.selectedKind) {
          const standard = (currentCabinet() || {}).defaults || {};
          setText('depth', standard.depth);
          setText('height', standard.height);
        }
        if (state.selectedKind && $('liveSizes').checked) $('width').dispatchEvent(new Event('input', { bubbles: true })); // (the selected cabinet takes the standard width live, like a typed one)
      }
      drawPreview();
    });
    $('width').addEventListener('input', syncWidthPreset);
    $('units').addEventListener('change', () => setUnit($('units').value));
    THICKNESS_PAIRS.forEach(([presetId, inputId]) => {
      $(presetId).addEventListener('change', () => {
        if ($(presetId).value !== 'custom') setText(inputId, Number($(presetId).value));
        drawPreview();
      });
      $(inputId).addEventListener('input', syncThicknessPresets);
    });
    $('handle').addEventListener('change', () => { onHandleChange(true); lockActions(); });
$('kitchenLayout').addEventListener('change', syncWallChoices);
$('kitchenLayout').addEventListener('change', () => {
  setSoft($('kitchenWallBField'), $('kitchenLayout').value === 'straight');
  setSoft($('kitchenWallCField'), $('kitchenLayout').value !== 'u');
});
    $('kitchenVariation').addEventListener('change', syncVariation);
    $('panelOrientation').addEventListener('change', syncPanelUi);
    $('applianceKind').addEventListener('change', renderAppliances);
    $('resetUnitSizes').addEventListener('click', resetUnitSizes);
    $('kitchenIsland').addEventListener('change', () => setSoft($('kitchenIslandFields'), !$('kitchenIsland').checked));
    $('handlePosition').addEventListener('change', syncHandlePosition);
    $('handleOrientation').addEventListener('change', syncHandlePosition);
    $('handleHPlace').addEventListener('change', syncHandlePosition);

    document.querySelectorAll('input, select').forEach((el) => {
      const onEdit = () => {
        const field = el.closest('.field');
        if (field) field.classList.remove('invalid');
        if (el.matches('[data-material]')) updateChips();
        drawPreview();
        liveEdit(el); // update the selected item with what was just entered
        if (el.closest('#sub-end-panel') && el.id !== 'liveSidePanels') scheduleSidePanels(); // the panels placed by the Presets tick take the new Side Panel settings
        if (PRESET_IDS.includes(el.id)) schedulePresetSave();
        if (FOLLOWS_CABINET.includes(el.id)) state.touched.add(el.id); // the user's own value now
      };
      el.addEventListener('input', onEdit);
      el.addEventListener('change', onEdit);
    });

    document.querySelectorAll('[data-action]').forEach((button) => {
      button.addEventListener('click', () => runAction(button.dataset.action));
    });

    ['visCarcass', 'visDoor', 'visToe', 'showAppliances', 'showOven', 'showMicro', 'showSink', 'showHob', 'showHood', 'showFreeFridge', 'visWorktop', 'visSplash', 'showDirection', 'showWallDirection', 'hideWallHandles', 'showNames', 'hideBaseHandles', 'hideTallHandles', 'hideLoftHandles', 'showDoorSymbol'].forEach((id) => $(id).addEventListener('change', applyVisibility));

    window.addEventListener('focus', refreshMaterials);
  }

  // The tick for side panels on every exposed side: the Side Panel settings of Cabinet & Extras go with it, and are sent again when they change.
  async function sendSidePanels() {
    try {
      const res = await call('set_live_side_panels', { enabled: $('liveSidePanels').checked, values: collectEndPanel() });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  // The ticks that keep toe kicks, the wall unit bottom panels and the worktop up: the settings of their sections go with them (the Toe Kick,
  // Wall Bottom Panel and Worktop fields), and are sent again, by the buttons and live edits of those sections, when they change.
  const LIVE_PART_TICKS = {
    liveToeKicks: ['set_live_toe_kicks', () => collectToeKick()],
    liveWallBottom: ['set_live_wall_bottom', () => COLLECTORS.wall_bottom()],
    liveWorktop: ['set_live_worktop', () => collectWorktop()],
    liveLoft: ['set_live_loft', () => ({ height: mmv('sizeLoftH') })],
    liveLoftFollow: ['set_live_loft_follow', () => ({})],
    liveLoftBottom: ['set_live_loft_bottom', () => ({})],
    liveCeilingFiller: ['set_live_ceiling_filler', () => collectCeilingFiller()]
  };

  async function sendLivePart(id) {
    const [action, collector] = LIVE_PART_TICKS[id];
    try {
      const res = await call(action, { enabled: $(id).checked, values: collector() });
      setStatus(res.ok ? 'ok' : 'error', res.message);
    } catch (error) {
      setStatus('error', error.message);
    }
  }

  function scheduleSidePanels() {
    if (!$('liveSidePanels').checked) return;
    clearTimeout(state.sideTimer);
    state.sideTimer = setTimeout(sendSidePanels, 700);
  }

  function followSelection() {
    const box = $('followSelection');
    return !box || box.checked;
  }

  async function init() {
    wireFeedback();
    wireDonate();
    wireMore();
    wireCommunity();
    wireActiveTile();
    wrapCardBodies();
    wireCardPrefs();
    try {
      if (localStorage.getItem('ec.followSelection') === 'off') $('followSelection').checked = false;
    } catch (_) { /* no stored choice: it follows */ }
    $('liveDimensions').addEventListener('change', async () => {
      try {
        const res = await call('set_live_dimensions', { enabled: $('liveDimensions').checked });
        setStatus(res.ok ? 'ok' : 'error', res.message);
      } catch (error) {
        setStatus('error', error.message);
      }
    });
    $('liveSidePanels').addEventListener('change', () => sendSidePanels());
    Object.keys(LIVE_PART_TICKS).forEach((id) => $(id).addEventListener('change', () => sendLivePart(id)));
    $('snapEnabled').addEventListener('change', async () => {
      try {
        const res = await call('set_snap', { enabled: $('snapEnabled').checked });
        setStatus(res.ok ? 'ok' : 'error', res.message);
      } catch (error) {
        setStatus('error', error.message);
      }
    });
    $('followSelection').addEventListener('change', () => {
      try { localStorage.setItem('ec.followSelection', followSelection() ? 'on' : 'off'); } catch (_) { /* not remembered */ }
      if (!followSelection()) { state.heldKind = state.selectedKind === 'cabinet' ? 'cabinet' : null; state.selectedKind = null; state.wallBottomSelected = false; clearTimeout(state.liveTimer); setBadge(null); }
    });
    enableCardOrder();
    enableSmoothScroll($('scroll'));
    wireEvents();
    try {
      const saved = localStorage.getItem('ec.unit');
      if (UNITS[saved]) state.unit = saved;
    } catch (_) { /* no stored choice: millimetres */ }
    // Every section starts closed; the user opens the ones they need.
    document.querySelectorAll('.card').forEach((card) => {
      if (card.querySelector('.card-head')) toggleCard(card, false);
    });
    try {
      const res = await call('init');
      if (!res.ok) throw new Error(res.message || 'The panel could not start.');
      state.meta = normaliseMeta(res.data);
      state.roomBuilt = res.data.room_built === true; // (a room that is in the model already: its fields are live)
      $('snapEnabled').checked = res.data.snap_enabled !== false;
      $('liveDimensions').checked = res.data.live_dimensions === true;
      $('liveSidePanels').checked = res.data.live_side_panels !== false;
      $('liveToeKicks').checked = res.data.live_toe_kicks !== false;
      $('liveWallBottom').checked = res.data.live_wall_bottom !== false;
      $('liveWorktop').checked = res.data.live_worktop !== false;
      $('liveCeilingFiller').checked = res.data.live_ceiling_filler !== false;
      $('liveLoft').checked = res.data.live_loft === true; // (off to begin with)
      $('liveLoftFollow').checked = res.data.live_loft_follow === true; // (off to begin with)
      $('liveLoftBottom').checked = res.data.live_loft_bottom !== false; // (on to begin with)
      await buildUi();
      if ($('liveSidePanels').checked) await sendSidePanels(); // (on to begin with: the Side Panel settings of the panel go with it)
      for (const id of Object.keys(LIVE_PART_TICKS)) { if ($(id).checked) await sendLivePart(id); } // (and the settings of the toe kick, bottom panel and worktop sections)
    } catch (error) {
      setStatus('error', error.message);
    }
    // From here on, sections slide open and shut.
    requestAnimationFrame(() => requestAnimationFrame(() => { state.animate = true; }));
  }

  // Any error the panel itself throws is shown, with where it happened, instead of failing silently.
  function reportError(message, where) {
    const text = `Panel error: ${message}${where ? ` (${where})` : ''}`;
    if (window.console) console.error(text);
    setStatus('error', text);
  }
  window.addEventListener('error', (event) => {
    const file = String(event.filename || '').split('/').pop();
    reportError(event.message, file ? `${file}:${event.lineno}` : '');
  });
  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    reportError(reason && reason.message ? reason.message : String(reason), (reason && reason.stack || '').split('\n')[1]?.trim());
  });

  window.addEventListener('load', init);
})();
