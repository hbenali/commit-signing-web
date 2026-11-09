/* Pull-cord lamp: switches between the light and dark theme.
   Lamp on = light theme. The choice is stored in localStorage; until it is made the page
   follows the system setting (see site.css). Loaded as a classic script in <head> so a stored
   choice is applied before first paint. Self-contained: no dependencies, no inline code (CSP). */
(function () {
    'use strict';
    var KEY = 'theme';
    var root = document.documentElement;
    var LABELS = {
        en: { light: 'Switch to light mode', dark: 'Switch to dark mode' },
        fr: { light: 'Passer en mode clair', dark: 'Passer en mode sombre' },
        ar: { light: 'التبديل إلى الوضع الفاتح', dark: 'التبديل إلى الوضع الداكن' }
    };
    var SVG = 'http://www.w3.org/2000/svg';

    try {
        var stored = localStorage.getItem(KEY);
        if (stored === 'light' || stored === 'dark') root.dataset.theme = stored;
    } catch (e) { /* storage blocked: follow the system */ }

    var lightMq = window.matchMedia('(prefers-color-scheme: light)');
    var reducedMq = window.matchMedia('(prefers-reduced-motion: reduce)');

    function current() {
        var t = root.dataset.theme;
        return t === 'light' || t === 'dark' ? t : (lightMq.matches ? 'light' : 'dark');
    }

    // Keep the browser UI colour (theme-color) in step with an explicit choice.
    // These are the sites' --ink values; setting them directly works before the CSS has loaded.
    var INK = { dark: '#0c1218', light: '#f4efe4' };
    function syncThemeColor(theme) {
        var metas = document.querySelectorAll('meta[name="theme-color"]');
        for (var i = 0; i < metas.length; i++) {
            metas[i].removeAttribute('media');
            metas[i].setAttribute('content', INK[theme]);
        }
    }
    if (root.dataset.theme) syncThemeColor(root.dataset.theme);

    function el(name, attrs, parent) {
        var n = document.createElementNS(SVG, name);
        for (var k in attrs) n.setAttribute(k, attrs[k]);
        if (parent) parent.appendChild(n);
        return n;
    }

    function build() {
        var lang = (root.lang || 'en').slice(0, 2).toLowerCase();
        var labels = LABELS[lang] || LABELS.en;

        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'theme-lamp';

        var svg = el('svg', { viewBox: '0 0 44 84', 'aria-hidden': 'true', focusable: 'false' }, btn);
        var defs = el('defs', {}, svg);
        var grad = el('linearGradient', { id: 'lamp-cone', x1: '0', y1: '0', x2: '0', y2: '1' }, defs);
        el('stop', { offset: '0', class: 'lamp-stop-a' }, grad);
        el('stop', { offset: '1', class: 'lamp-stop-b' }, grad);

        var body = el('g', {}, svg);
        el('polygon', { class: 'lamp-cone', points: '13,38 31,38 42,80 2,80' }, body);
        el('line', { class: 'lamp-wire', x1: '22', y1: '0', x2: '22', y2: '14' }, body);
        el('circle', { class: 'lamp-halo', cx: '22', cy: '36', r: '13' }, body);
        el('path', { class: 'lamp-shade', d: 'M10 32 C10 20 15 14 22 14 C29 14 34 20 34 32 Z' }, body);
        el('circle', { class: 'lamp-bulb', cx: '22', cy: '36', r: '4.5' }, body);
        var cord = el('g', {}, body);
        el('line', { class: 'lamp-cord', x1: '33', y1: '31', x2: '33', y2: '58' }, cord);
        el('circle', { class: 'lamp-bead', cx: '33', cy: '60', r: '2.6' }, cord);

        function render() {
            var light = current() === 'light';
            btn.dataset.on = light ? 'true' : 'false';
            btn.setAttribute('aria-label', light ? labels.dark : labels.light);
        }

        // The swing and the cord pull are one-shot animations, replayed on each use.
        function replay(node, cls) {
            node.classList.remove(cls);
            void node.getBoundingClientRect();
            node.classList.add(cls);
        }

        btn.addEventListener('click', function () {
            var next = current() === 'light' ? 'dark' : 'light';
            function apply() {
                root.dataset.theme = next;
                render();
                syncThemeColor(next);
            }
            try { localStorage.setItem(KEY, next); } catch (e) { /* choice lasts for this page only */ }
            replay(body, 'lamp-swing');
            replay(cord, 'lamp-pull');
            if (reducedMq.matches || !document.startViewTransition) {
                apply();
                return;
            }
            root.classList.add('theme-vt');
            document.startViewTransition(apply).finished.then(function () {
                root.classList.remove('theme-vt');
            }, function () {
                root.classList.remove('theme-vt');
            });
        });

        lightMq.addEventListener('change', function () { if (!root.dataset.theme) render(); });
        render();
        document.body.appendChild(btn);
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', build);
    else build();
})();
