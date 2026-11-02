/* Nodio landing page: reveal on scroll and copy-to-clipboard. */
(() => {
  'use strict';

  const root = document.documentElement;
  const items = document.querySelectorAll('.reveal');

  if ('IntersectionObserver' in window && items.length) {
    root.classList.add('js');
    // Stagger siblings inside the same grid so a row eases in left to right.
    items.forEach((el) => {
      const siblings = [...el.parentElement.children].filter((c) => c.classList.contains('reveal'));
      el.style.setProperty('--i', String(Math.min(siblings.indexOf(el), 6)));
    });
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        e.target.classList.add('is-visible');
        io.unobserve(e.target);
      }
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    items.forEach((el) => io.observe(el));
  }

  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const src = document.getElementById(btn.dataset.copy);
      const status = btn.closest('details')?.querySelector('.copy-status');
      if (!src) return;
      try {
        await navigator.clipboard.writeText(src.textContent.trim());
        if (status) status.textContent = 'Copied. Paste it into Terminal and press Return.';
      } catch {
        const range = document.createRange();
        range.selectNodeContents(src);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        if (status) status.textContent = 'Press Command C to copy the selected command.';
      }
    });
  });
})();
