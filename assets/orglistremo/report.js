  function toggleAll(open) {
    document.querySelectorAll('details').forEach(
      function(d) { d.open = open; }
    );
  }
