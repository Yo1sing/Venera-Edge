// Private transport codec. Every value is tagged, so user objects cannot be
// mistaken for function handles, promises or binary buffers at the FRB boundary.
globalThis.__venera = (() => {
    let next = 1;
    const handles = new Map();
    const promises = new Map();
    const tickets = new Map();
    function pack(value, seen = new Set()) {
        if (value === null || value === undefined) return ['null'];
        if (typeof value === 'boolean') return ['bool', value];
        if (typeof value === 'number') return ['number', Number.isFinite(value) ? value : String(value)];
        if (typeof value === 'bigint') return ['bigint', String(value)];
        if (typeof value === 'string') return ['string', value];
        if (typeof value === 'function') {
            const id = next++; handles.set(id, {value, refs: 1}); return ['function', id];
        }
        if (value instanceof Promise) {
            const id = next++;
            promises.set(id, null);
            value.then(v => {
                if (promises.has(id)) promises.set(id, {value: pack(v)});
            }, e => {
                if (promises.has(id)) {
                    promises.set(id, {error: [String(e), e?.stack].filter(Boolean).join('\n')});
                }
            });
            return ['promise', id];
        }
        if (value instanceof ArrayBuffer) return ['bytes', Array.from(new Uint8Array(value))];
        if (ArrayBuffer.isView(value)) return ['bytes', Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))];
        if (value instanceof Date) return ['string', value.toISOString()];
        if (value instanceof Map) {
            if (seen.has(value)) throw new Error('Cannot transfer cyclic JavaScript object');
            seen.add(value);
            const result = ['object', Array.from(value, ([key, item]) => [String(key), pack(item, seen)])];
            seen.delete(value);
            return result;
        }
        if (seen.has(value)) throw new Error('Cannot transfer cyclic JavaScript object');
        seen.add(value);
        const result = Array.isArray(value) ? ['array', value.map(v => pack(v, seen))]
            : ['object', Object.entries(value).map(([k,v]) => [k, pack(v, seen)])];
        seen.delete(value);
        return result;
    }
    function unpack(wire) {
        switch (wire[0]) {
            case 'null': return null;
            case 'bool': case 'string': return wire[1];
            case 'number': return Number(wire[1]);
            case 'bigint': return BigInt(wire[1]);
            case 'bytes': return new Uint8Array(wire[1]).buffer;
            case 'array': return wire[1].map(unpack);
            case 'object': return Object.fromEntries(wire[1].map(([k,v]) => [k, unpack(v)]));
            case 'function': {
                const handle = handles.get(wire[1]);
                if (!handle) throw new Error('JavaScript function is released');
                return handle.value;
            }
            default: throw new Error('Unknown bridge value');
        }
    }
    function sendNative(message) {
        const response = JSON.parse(__nativeHost(JSON.stringify(pack(message))));
        if (response.error) throw new Error(response.error);
        if (response.ticket !== undefined) return new Promise((resolve,reject) => tickets.set(response.ticket, {resolve,reject}));
        return unpack(response.value);
    }

    // A dynamic getter can consult saved settings while calculating its options.
    const resolvingSettings = new Set();
    // Some sources assign runtime values directly to their setting descriptors,
    // e.g. `this.settings.base_url = fetchedDomain`. Preserve the last valid
    // descriptor and expose the assigned primitive as its default instead of
    // destroying the setting control.
    const rememberedSettings = new Map();
    const isDefinition = value => value !== null && typeof value === 'object';

    function liveSettings(key) {
        if (resolvingSettings.has(key)) return null;
        resolvingSettings.add(key);
        try {
            return ComicSource.sources[key]?.settings;
        } finally {
            resolvingSettings.delete(key);
        }
    }

    function rememberSettings(key) {
        try {
            const settings = liveSettings(key);
            if (!isDefinition(settings)) return;
            const remembered = {};
            for (const [name, field] of Object.entries(settings))
                if (isDefinition(field)) remembered[name] = field;
            rememberedSettings.set(key, remembered);
        }
        catch (_) {
            // A dynamic settings getter must not make activation fail.
        }
    }

    function definitions(key) {
        const settings = liveSettings(key);
        const previous = rememberedSettings.get(key);
        if (!isDefinition(settings))
            return previous ?? settings;
        const fields = {};
        const remembered = {};
        for (const [name, value] of Object.entries(settings)) {
            const definition = isDefinition(value)
                ? value
                : isDefinition(previous?.[name])
                    ? {...previous[name], default: value}
                    : value;
            fields[name] = definition;
            if (isDefinition(definition)) remembered[name] = definition;
        }
        rememberedSettings.set(key, remembered);
        return fields;
    }

    function forgetSettings(key) {
        rememberedSettings.delete(key);
    }

    function descriptor(field) {
        if (!field || typeof field !== 'object') return null;
        return {
            type: field.type,
            default: field.default,
            options: Array.isArray(field.options) ? field.options.map(option => option?.value) : [],
            validator: typeof field.validator === 'string' ? field.validator : null,
        };
    }

    function readSetting(key, setting_key, field) {
        return sendNative({method: 'load_setting', key, setting_key, definition: descriptor(field)});
    }

    globalThis.sendMessage = message => {
        if (message.method === 'load_setting') {
            return readSetting(message.key, message.setting_key, definitions(message.key)?.[message.setting_key]);
        }
        if (message.method === 'edit_source_setting') throw new Error('Source settings are read-only to scripts');
        return sendNative(message);
    };

    return {
        pack, unpack,
        rememberSettings, forgetSettings,
        sourceSettings: key => Object.fromEntries(Object.entries(definitions(key) ?? {}).map(([name, field]) =>
            [name, {...field, effectiveValue: readSetting(key, name, field)}])),
        editSourceSetting: (key, setting_key, value, reset) => sendNative({
            method: 'edit_source_setting', key, setting_key, value, reset,
            definition: descriptor(definitions(key)?.[setting_key]),
        }),
        evaluate: source => JSON.stringify(pack((0,eval)(source))),
        call: (id,args) => JSON.stringify(pack(unpack(['function',id])(...unpack(args)))),
        retain: id => { const handle=handles.get(id); if (!handle) throw new Error('JavaScript function is released'); handle.refs++; },
        release: id => {const handle=handles.get(id); if (handle && --handle.refs<=0) handles.delete(id);},
        promise: id => {if (!promises.has(id)) throw new Error('Unknown promise'); const value=promises.get(id); if(value!==null) promises.delete(id); return JSON.stringify(value);},
        discardPromise: id => promises.delete(id),
        settle: (id,value,error) => {const ticket=tickets.get(id); if(ticket){tickets.delete(id); error ? ticket.reject(new Error(error)) : ticket.resolve(unpack(value));}},
    };
})();
