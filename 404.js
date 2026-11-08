(function () {
  var path = decodeURIComponent(window.location.pathname) || "/";
  var code = document.getElementById("pathCode");
  if (code) code.textContent = path;
})();
