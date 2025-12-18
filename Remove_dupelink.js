var style = document.createElement('style');
style.type = 'text/css';
style.id = 'hide-print-links';
style.textContent = `
@media print {
  a[href]:after {
    content: none !important; /* prevent browser adding [1] etc */
  }
  .footnotes,
  .reference-links {
    display: none !important; /* hide HackMD reference list */
  }
}`;
document.head.appendChild(style);
