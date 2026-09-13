/* ============================================================
   Nodio — script.js
   Scroll reveal animations
   ============================================================ */

(function () {
  'use strict';

  /* --- Scroll Reveal --- */
  const revealElements = document.querySelectorAll('.fade-up, .pop-in');

  if ('IntersectionObserver' in window && revealElements.length > 0) {
    const observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry, index) {
          if (entry.isIntersecting) {
            // Stagger by a small delay based on index within the same group
            setTimeout(function () {
              entry.target.classList.add('visible');
            }, index * 60);
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.15, rootMargin: '0px 0px -40px 0px' }
    );

    revealElements.forEach(function (el) {
      observer.observe(el);
    });
  } else {
    // Fallback — show everything
    revealElements.forEach(function (el) {
      el.classList.add('visible');
    });
  }
})();