// Source loading, validation and account state execute inside Rust's QuickJS worker.
globalThis.__sources = {
    codes: new Map(),
    prepared: new Map(),
    active: new Map(),
    blocked: new Set(),
    generations: new Map(),
    next: 1,
    snapshot() { return Object.keys(ComicSource.sources).map(key => this.codes.get(key)).filter(code => typeof code === 'string'); },
    newer(a, b) {
        const x = a.replace('-', '.').split('.'), y = b.replace('-', '.').split('.');
        for (let i = 0; i < 3; i++) {
            const l = Number(x[i] ?? 0), r = Number(y[i] ?? 0);
            if (!Number.isFinite(l) || !Number.isFinite(r))
                throw Error('Invalid source version');
            if (l !== r)
                return l > r;
        }
        if (x[3] === y[3])
            return false;
        if (x[3] === undefined)
            return y[3] !== 'hotfix';
        if (y[3] === undefined)
            return x[3] === 'hotfix';
        return x[3] > y[3];
    },
    normalizeOptions(values, search = false) {
        if (values == null)
            return;
        if (!Array.isArray(values))
            throw Error('optionList must be a list');
        for (const option of values) {
            if (!option || typeof option !== 'object' || !Array.isArray(option.options))
                throw Error('Invalid source option');
            if (option.label != null && typeof option.label !== 'string')
                throw Error('Invalid option label');
            if (option.type != null && typeof option.type !== 'string')
                throw Error('Invalid option type');
            if (search && option.default != null) {
                JSON.stringify(option.default, (key, value) => {
                    if (typeof value === 'function' || typeof value === 'bigint')
                        throw Error('Search option default must be JSON data');
                    return value;
                });
            }
            if (search)
                option.label ??= '';
            for (const field of ['notShowWhen', 'showWhen'])
                if (option[field] != null && (!Array.isArray(option[field]) || option[field].some(value => typeof value !== 'string')))
                    throw Error('Invalid ' + field);
            option._options = Object.create(null);
            for (const value of option.options) {
                if (typeof value !== 'string')
                    throw Error('Source option must be a string');
                const separator = value.indexOf('-');
                if (separator < 0)
                    continue;
                option._options[value.slice(0, separator)] = value.slice(separator + 1);
            }
        }
        return values;
    },
    descriptor(source) {
        const fields = ['account', 'comic', 'category', 'categoryComics', 'favorites', 'explore', 'search', 'settings', 'translation'];
        return Object.fromEntries(fields.map(field => [field, source[field] ?? null]));
    },
    describe(key) {
        const source = ComicSource.sources[key];
        if (!source)
            throw Error('Comic source not found');
        return this.descriptor(source);
    },
    validate(source) {
        const object = (value, path) => {
            if (value === null || typeof value !== 'object' || Array.isArray(value))
                throw Error(path + ' must be an object');
        };
        const string = (value, path) => {
            if (typeof value !== 'string')
                throw Error(path + ' must be a string');
        };
        const list = (value, path) => {
            if (!Array.isArray(value))
                throw Error(path + ' must be a list');
        };
        const strings = (value, path) => { list(value, path); value.forEach(x => string(x, path)); };
        const optional = (value, type, path) => {
            if (value != null && typeof value !== type)
                throw Error(path + ' must be ' + type);
        };
        for (const name of ['account', 'comic', 'category', 'categoryComics', 'search', 'favorites', 'settings', 'translation'])
            if (source[name] != null)
                object(source[name], name);
        optional(source.url, 'string', 'url');
        optional(source.account?.registerWebsite, 'string', 'account.registerWebsite');
        optional(source.account?.loginWithWebview?.url, 'string', 'account.loginWithWebview.url');
        optional(source.comic?.idMatch, 'string', 'comic.idMatch');
        optional(source.search?.enableTagsSuggestions, 'boolean', 'search.enableTagsSuggestions');
        optional(source.comic?.enableTagsTranslate, 'boolean', 'comic.enableTagsTranslate');
        if (source.comic?.idMatch)
            new RegExp(source.comic.idMatch);
        if (source.comic?.link)
            strings(source.comic.link.domains, 'comic.link.domains');
        if (source.explore != null) {
            list(source.explore, 'explore');
            for (const page of source.explore) {
                object(page, 'explore page');
                string(page.title, 'explore.title');
                if (!['singlePageWithMultiPart', 'multiPartPage', 'multiPageComicList', 'mixed'].includes(page.type))
                    throw Error('Unknown explore page type ' + page.type);
                if (typeof page.load !== 'function' && typeof page.loadNext !== 'function')
                    throw Error('Explore loader is required');
            }
        }
        if (source.favorites) {
            optional(source.favorites.multiFolder, 'boolean', 'favorites.multiFolder');
            source.favorites.multiFolder ??= false;
            for (const field of ['isOldToNewSort', 'singleFolderForSingleComic'])
                optional(source.favorites[field], 'boolean', 'favorites.' + field);
        }
        if (source.category?.title != null) {
            string(source.category.title, 'category.title');
            optional(source.category.enableRankingPage, 'boolean', 'category.enableRankingPage');
            list(source.category.parts, 'category.parts');
            source.category.parts = source.category.parts.filter(part => part.categories == null || (Array.isArray(part.categories) && part.categories.length > 0));
            for (const part of source.category.parts) {
                object(part, 'category part');
                string(part.name, 'category.name');
                string(part.type, 'category.type');
                if (part.categories != null) {
                    list(part.categories, 'categories');
                    const legacy = typeof part.categories[0] === 'string';
                    for (const item of part.categories) {
                        if ((typeof item === 'string') !== legacy)
                            throw Error('Category items must use the same format');
                        if (typeof item === 'string') {
                            string(part.itemType, 'category.itemType');
                        }
                        else {
                            object(item, 'category item');
                            string(item.label, 'category.label');
                            if (typeof item.target === 'string') {
                                const segments = item.target.split(':');
                                if (['search', 'category'].includes(segments[0]) && segments.length < 2)
                                    throw Error('Category target requires a value');
                            }
                            else if (item.target != null) {
                                object(item.target, 'category.target');
                                optional(item.target.page, 'string', 'category.target.page');
                                optional(item.target.action, 'string', 'category.target.action');
                                if (item.target.attributes != null)
                                    object(item.target.attributes, 'category.target.attributes');
                            }
                        }
                    }
                }
                else if (part.type === 'dynamic' && typeof part.loader !== 'function')
                    throw Error('DynamicCategoryPart loader must be a function');
                if (part.randomNumber != null && (!Number.isInteger(part.randomNumber) || part.randomNumber < 0))
                    throw Error('Invalid category randomNumber');
                if (part.categoryParams != null)
                    strings(part.categoryParams, 'categoryParams');
                optional(part.groupParam, 'string', 'groupParam');
                if (part.categories?.length && typeof part.categories[0] === 'string') {
                    part.categories = part.categories.map((label, index) => {
                        let page = part.itemType, attributes = null;
                        if (page === 'category')
                            attributes = { category: label, param: part.groupParam ?? part.categoryParams?.[index] ?? null };
                        if (page === 'search')
                            attributes = { keyword: label };
                        if (page === 'search_with_namespace') {
                            page = 'search';
                            attributes = { keyword: part.name + ':' + label };
                        }
                        return { label, target: { page, attributes } };
                    });
                }
            }
        }
        this.normalizeOptions(source.categoryComics?.optionList);
        this.normalizeOptions(source.search?.optionList, true);
        if (source.categoryComics?.ranking) {
            const ranking = source.categoryComics.ranking;
            ranking._options = this.normalizeOptions([{ options: ranking.options }])[0]._options;
        }
        if (source.settings)
            for (const setting of Object.values(source.settings))
                object(setting, 'setting');
        if (source.translation)
            for (const map of Object.values(source.translation)) {
                object(map, 'translation');
                for (const value of Object.values(map))
                    string(value, 'translation value');
            }
        if (source.account?.loginWithCookies?.fields)
            strings(source.account.loginWithCookies.fields, 'cookie fields');
    },
    prepare(code, expectedKey = null) {
        const declaration = code.match(/^\s*class\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource\b/m);
        if (!declaration)
            throw Error('Invalid comic source: missing ComicSource class');
        const source = (new Function(code + '\n;return new ' + declaration[1] + '();'))();
        for (const field of ['name', 'key', 'version'])
            if (typeof source[field] !== 'string' || !source[field])
                throw Error(field + ' is required');
        if (!/^[A-Za-z0-9_]+$/.test(source.key))
            throw Error('Invalid source key');
        if (expectedKey !== null && source.key !== expectedKey)
            throw Error('Source key cannot change from ' + expectedKey + ' to ' + source.key);
        if (source.minAppVersion && this.newer(source.minAppVersion, appVersion.split('-')[0]))
            throw Error('minAppVersion ' + source.minAppVersion + ' is required');
        if (source.idMatch)
            new RegExp(source.idMatch);
        this.validate(source);
        if (typeof source.categoryComics?.optionLoader === 'function') {
            const original = source.categoryComics.optionLoader, self = this;
            source.categoryComics.optionLoader = async function (...args) {
                return self.normalizeOptions(await original.apply(this, args));
            };
        }
        if (source.account?.login) {
            const original = source.account.login;
            source.account.login = async function (account, password) {
                const result = await original.call(this, account, password);
                source.saveData('account', [account, password]);
                return result;
            };
        }
        const wrap = (object, name, requireLogin) => {
            if (typeof object?.[name] !== 'function')
                return;
            const original = object[name];
            object[name] = async function (...args) {
                if (requireLogin && !source.isLogged)
                    throw Error('Not login');
                try {
                    return await original.apply(this, args);
                }
                catch (error) {
                    if (!String(error).includes('Login expired'))
                        throw error;
                    if (!await __sources.reLogin(source.key))
                        throw Error('Login expired and re-login failed');
                    return original.apply(this, args);
                }
            };
        };
        for (const name of Object.keys(source.favorites ?? {}))
            wrap(source.favorites, name, true);
        for (const name of ['sendComment', 'sendChapterComment'])
            wrap(source.comic, name, false);
        const token = String(this.next++);
        const generation = String(this.next++);
        const metadata = this.metadata(source);
        const visited = new Set();
        const transferable = value => {
            if (!value || typeof value !== 'object')
                return;
            if (visited.has(value))
                throw Error('Cyclic source configuration');
            visited.add(value);
            for (const child of Object.values(value))
                transferable(child);
            visited.delete(value);
        };
        transferable(this.descriptor(source));
        this.track(source, generation, metadata.key);
        this.prepared.set(token, { source, code, generation, metadata });
        return { token, ...metadata };
    },
    metadata(source) {
        return { name: source.name, key: source.key, version: source.version, url: source.url ?? '',
            explore_titles: (source.explore ?? []).map(page => page.title), category_title: source.category?.title ?? null,
            favorites_title: source.favorites ? source.name : null, search_enabled: source.search != null };
    },
    tryBlock(key) {
        if ((this.active.get(key) ?? 0) !== 0)
            return false;
        this.blocked.add(key);
        return true;
    },
    unblock(key) { this.blocked.delete(key); },
    discard(token) { this.prepared.delete(token); },
    track(source, generation, key) {
        const seen = new Set(), guarded = new WeakSet(), self = this;
        const visit = object => {
            if (!object || typeof object !== 'object' || seen.has(object))
                return;
            seen.add(object);
            for (const [name, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(object))) {
                if (!('value' in descriptor) || !descriptor.writable)
                    continue;
                const value = descriptor.value;
                if (typeof value === 'function') {
                    if (guarded.has(value))
                        continue;
                    object[name] = function (...args) {
                        if (self.generations.get(key) !== generation)
                            throw Error('Source changed; refresh this page');
                        if (self.blocked.has(key))
                            throw Error('Source is being updated');
                        self.active.set(key, (self.active.get(key) ?? 0) + 1);
                        const done = () => self.active.set(key, (self.active.get(key) ?? 1) - 1);
                        try {
                            const result = value.apply(this, args);
                            if (result instanceof Promise)
                                return result.finally(done);
                            done();
                            return result;
                        }
                        catch (error) {
                            done();
                            throw error;
                        }
                    };
                    guarded.add(object[name]);
                }
                else if (value && typeof value === 'object')
                    visit(value);
            }
            seen.delete(object);
        };
        for (const field of ['account', 'comic', 'explore', 'category', 'categoryComics', 'search', 'favorites', 'settings']) {
            let owner = source;
            while (owner && !Object.prototype.hasOwnProperty.call(owner, field)) {
                owner = Object.getPrototypeOf(owner);
            }
            const descriptor = owner && Object.getOwnPropertyDescriptor(owner, field);
            if (descriptor?.get) {
                Object.defineProperty(source, field, {
                    configurable: true,
                    enumerable: descriptor.enumerable,
                    get() {
                        const value = descriptor.get.call(this);
                        visit(value);
                        return value;
                    },
                    set: descriptor.set,
                });
            }
            else {
                visit(source[field]);
            }
        }
    },
    activate(token) {
        const candidate = this.prepared.get(token);
        if (!candidate)
            throw Error('Missing prepared source');
        const { source, code, generation, metadata } = candidate;
        Object.defineProperty(ComicSource.sources, metadata.key, { value: source, writable: true, configurable: true, enumerable: true });
        this.generations.set(metadata.key, generation);
        this.codes.set(metadata.key, code);
        this.prepared.delete(token);
        return metadata;
    },
    activateAll(tokens, removed) {
        for (const token of tokens)
            if (!this.prepared.has(token))
                throw Error('Missing prepared source');
        const previous = Object.getOwnPropertyDescriptors(ComicSource.sources);
        const codes = new Map(this.codes), generations = new Map(this.generations);
        try {
            const metadata = tokens.map(token => this.activate(token));
            for (const key of removed)
                this.remove(key);
            return metadata;
        }
        catch (error) {
            ComicSource.sources = Object.defineProperties({}, previous);
            this.codes = codes;
            this.generations = generations;
            throw error;
        }
    },
    install(code) {
        const metadata = this.prepare(code);
        if (Object.prototype.hasOwnProperty.call(ComicSource.sources, metadata.key)) {
            this.discard(metadata.token);
            throw Error('key(' + metadata.key + ') already exists');
        }
        return this.activate(metadata.token);
    },
    remove(key) {
        delete ComicSource.sources[key];
        this.codes.delete(key);
        this.generations.delete(key);
    },
    init(key) {
        const source = ComicSource.sources[key];
        if (typeof source?.init === 'function') {
            this.active.set(key, (this.active.get(key) ?? 0) + 1);
            Promise.resolve().then(() => source.init()).catch(e => console.error(String(e))).finally(() => this.active.set(key, (this.active.get(key) ?? 1) - 1));
        }
    },
    async reLogin(key) {
        const source = ComicSource.sources[key], account = source?.loadData('account');
        if (!Array.isArray(account) || !source.account?.login)
            return false;
        try {
            await source.account.login(...account);
            return true;
        }
        catch (error) {
            console.error(String(error));
            return false;
        }
    },
};
