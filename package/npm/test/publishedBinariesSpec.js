var request = require("request-promise");
var elmFormat = require("../elmFormatDownload");

function showUrl(url) {
  return function(error) {
    return Promise.reject(url + ": " + error);
  };
}

function checkBinary(os, arch) {
  return function() {
    var url = elmFormat.url(os, arch);
    return request.head(url).catch(showUrl(url));
  };
}

describe("published binaries", function() {
  it("(tests should be able to connect to the internet)", function() {
    return request.head("https://google.com");
  });

  it("should include Mac binaries", checkBinary("darwin", "x64"));
  it("should include Linux binaries", checkBinary("linux", "x64"));
  it("should include Windows binaries", checkBinary("win32", "x64"));
});
