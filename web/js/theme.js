/* Apply the saved theme before the page draws, so it doesn't flash the wrong one. */
try {
  var saved = localStorage.getItem('orbit-theme');
  if (saved === 'dark' || saved === 'light') document.documentElement.setAttribute('data-theme', saved);
} catch (e) { /* storage blocked: follow the system theme */ }
