default_phantom(entries) = first(entries) isa AbstractString ? first(entries) : first(entries)["default"]

registry_tree(entries) = map(entries) do entry
    entry isa AbstractString && return entry
    phantoms = registry_tree(entry["phantoms"])
    Dict("group" => entry["group"], "default" => get(entry, "default", default_phantom(phantoms)), "phantoms" => phantoms)
end

function registry_collections(catalog, registry)
    return [
        begin
            entry = registry[collection]
            phantoms = registry_tree(entry["phantoms"])
            Dict(
                "label" => label,
                "collection" => collection,
                "description" => entry["description"],
                "authors" => join(getindex.(entry["authors"], "name"), "; "),
                "license" => entry["license"],
                "doi" => entry["doi"],
                "default" => default_phantom(phantoms),
                "phantoms" => phantoms,
            )
        end for (label, collection) in catalog if haskey(registry, collection)
    ]
end

function setup_registry!(w::KomaWindow; phantom_file=Ref(""))
    pick = Observable{Any}(nothing)
    registry = Ref{Any}(nothing)

    handle(w, "registry") do _
        evaljs(w, js"KomaRegistry.open()")
        try
            isnothing(registry[]) || return evaljs(w, js"KomaRegistry.show($(registry[][2]))")
            reg = load_registry()
            registry[] = (reg, registry_collections(load_catalog(), reg))
            evaljs(w, js"KomaRegistry.show($(registry[][2]))")
        catch error
            evaljs(w, js"KomaRegistry.close()")
            failure_toast!(w, 0, "Loading the phantom registry", error)
        end
    end

    push!(w.listeners, on(pick) do selection
        isnothing(selection) && return nothing
        collection, name = String(selection["collection"]), String(selection["name"])
        toast!(w, 0, "Downloading <b>$(html_escape(name))</b>", "From the BIfTI registry, cached for next time.")
        try
            phantom_file[] = load_registry_phantom(collection, name; registry=registry[][1])
            obj_ui[] = callback_filepicker(phantom_file[], w, obj_ui[])
            evaljs(w, js"document.querySelector('#phafilepicker .koma-file-name').textContent = $(name)")
        catch error
            failure_toast!(w, 0, "Loading $name", error)
        end
        return nothing
    end)

    push!(w.on_render, session -> Bonito.on_document_load(session, js"""
        window.KomaRegistry = (() => {
            let data = [], selection = null, query = '';
            const opened = new Set();
            const h = (tag, {dataset, ...props} = {}, ...children) => {
                const node = Object.assign(document.createElement(tag), props);
                Object.assign(node.dataset, dataset);
                node.append(...children);
                return node;
            };
            const status = h('div', {className: 'koma-registry-status'});
            const search = h('input', {className: 'form-control form-control-sm', type: 'search', placeholder: 'Search collections, groups and phantoms...'});
            const tree = h('div', {className: 'koma-registry-tree'});
            const info = h('div', {className: 'koma-registry-info'});
            const close = h('button', {type: 'button', className: 'btn-close btn-close-white', title: 'Close'});
            const root = h('div', {className: 'koma-registry', hidden: true},
                h('div', {className: 'koma-registry-panel'},
                    h('div', {className: 'koma-registry-head'}, h('h5', {textContent: 'BIfTI phantom registry'}), close),
                    search,
                    h('div', {className: 'koma-registry-body'}, tree, info)));
            document.body.append(root);

            const hide = () => { root.hidden = true; };
            close.onclick = hide;
            root.onclick = event => { if (event.target === root) hide(); };
            document.addEventListener('keydown', event => { if (event.key === 'Escape') hide(); });

            const matches = (text, q) => text.toLowerCase().includes(q);
            const prune = (entries, q) => entries.flatMap(entry =>
                typeof entry === 'string' ? (matches(entry, q) ? [entry] : [])
                : matches(entry.group, q) ? [entry]
                : (kept => kept.length ? [{...entry, phantoms: kept}] : [])(prune(entry.phantoms, q)));

            const select = (collection, name, crumbs) => {
                selection = {collection, name, crumbs};
                refresh();
            };
            const leaf = (collection, name, crumbs, isDefault) => h('button', {
                type: 'button',
                className: 'koma-registry-leaf',
                onclick: () => select(collection, name, [...crumbs, name]),
                dataset: {collection, name},
            }, name, ...(isDefault ? [h('span', {className: 'koma-registry-default', textContent: ' \u2605', title: 'default'})] : []));
            const markSelected = () => tree.querySelectorAll('.koma-registry-leaf').forEach(button => {
                const {collection, name} = button.dataset;
                button.classList.toggle('active', !!selection && collection === selection.collection && name === selection.name);
            });
            const group = (collection, entry, crumbs, path) => {
                const here = [...crumbs, entry.group];
                const summary = h('summary', {}, entry.group);
                summary.addEventListener('click', () => select(collection, entry.default, [...here, entry.default]));
                const details = h('details', {open: query !== '' || opened.has(path)}, summary, ...entries(collection, entry.phantoms, entry.default, here, path));
                details.addEventListener('toggle', () => details.open ? opened.add(path) : opened.delete(path));
                return details;
            };
            const entries = (collection, list, defaultName, crumbs, path) => list.map(entry =>
                typeof entry === 'string'
                    ? leaf(collection, entry, crumbs, entry === defaultName)
                    : group(collection, entry, crumbs, path + '/' + entry.group));

            const renderTree = () => {
                const q = query.toLowerCase();
                const shown = data.flatMap(c => !q || [c.label, c.collection, c.description].some(t => matches(t, q))
                    ? [c] : (kept => kept.length ? [{...c, phantoms: kept}] : [])(prune(c.phantoms, q)));
                tree.replaceChildren(...(shown.length ? shown : [h('div', {className: 'koma-registry-status', textContent: 'No matches'})]).map(c => {
                    if (!c.collection) return c;
                    const summary = h('summary', {}, h('b', {textContent: c.label}));
                    summary.addEventListener('click', () => select(c.collection, c.default, [c.label, c.default]));
                    const details = h('details', {open: q !== '' || opened.has(c.collection)}, summary, ...entries(c.collection, c.phantoms, c.default, [c.label], c.collection));
                    details.addEventListener('toggle', () => details.open ? opened.add(c.collection) : opened.delete(c.collection));
                    return details;
                }));
                refresh();
            };

            const refresh = () => {
                markSelected();
                const collection = selection && data.find(c => c.collection === selection.collection);
                const row = (term, value) => [h('dt', {textContent: term}), h('dd', {textContent: value})];
                const load = h('button', {type: 'button', className: 'btn btn-primary btn-sm mt-auto', disabled: !selection, textContent: 'Load phantom'});
                load.onclick = () => { hide(); $(pick).notify({collection: selection.collection, name: selection.name}); };
                info.replaceChildren(...(collection ? [
                    h('div', {textContent: collection.description}),
                    h('dl', {}, ...row('Selected', selection.crumbs.join(' › ')), ...row('Authors', collection.authors),
                        ...row('License', collection.license), ...row('DOI', collection.doi)),
                ] : [h('div', {className: 'koma-registry-status', textContent: 'Select a collection, group or phantom. Groups and collections select their default ★.'})]), load);
            };
            search.oninput = () => { query = search.value.trim(); renderTree(); };

            return {
                open() { data = []; query = search.value = ''; selection = null; tree.replaceChildren(h('div', {className: 'koma-registry-status', textContent: 'Loading registry...'})); refresh(); root.hidden = false; },
                show(collections) { data = collections; renderTree(); },
                close: hide,
            };
        })();
        """))
    return nothing
end
