part of WebCrawler;

class WebCrawler {
  final List<String> crawlList = <String>[];
  final List<String> alreadyScrapedUrls = <String>[];
  final List<String> erredScrapedUrls = <String>[];
  final StreamController<String> controller = new StreamController<String>();

  /// The maximum number of recursive depths for the crawl to travel; default is 10.
  int maxCrawlsAmount = 10;

  /// The space to wait between each Url fetch (to avoid risking getting blacklisted).
  Duration crawlSleepTime = const Duration(milliseconds: 800);

  /// The amount of crawls deep that you currently are.
  int currentNumberOfCrawls = 0;
  String startUrl;
  String currentUrlToScrape;

  bool shouldBeVerbose = false;

  WebCrawler(final String this.startUrl) {
    if (shouldBeVerbose) serverLogger.log('WebCrawler() [constructor]');

    this.currentUrlToScrape = this.startUrl;
  }

  /**
   * Kick-up the process for the crawl; this function is recursive to the depth of the maxCrawl.
   */
  Stream<String> dispatchCrawl([final String nextUrlToCrawl]) {
    if (shouldBeVerbose) {
      serverLogger.log('WebCrawler.dispatchCrawl()');
      serverLogger.log('Crawl number: (${this.currentNumberOfCrawls})');
    }

    if (nextUrlToCrawl != null) {
      this.currentUrlToScrape = nextUrlToCrawl;
    }

    // Make sure that the provided info is valid to begin the scraping process.
    if (this.startUrl == null) {
      throw 'You must supply a URL to start the crawl at.';
    } else if (this.alreadyScrapedUrls.contains(this.startUrl)) { // Check if the Url has already been scraped
      if (shouldBeVerbose) serverLogger.log('You have already scraped this page.');
    }

    // Load the current run's Url and parse it for links
    this._parseForLinks().then((_) {
      if (shouldBeVerbose) serverLogger.log('completed this._parseForLinks()');

      // Send the crawled Url to the stream subscriber
      this.controller.add(this.currentUrlToScrape);

      // Increment the current number of crawls
      this.currentNumberOfCrawls++;

      // If current number of crawls is greater than the max, then return and finish
      if (this.currentNumberOfCrawls >= this.maxCrawlsAmount) {
        return;
      } else if (this.crawlList.length > 0) { // Otherwise, scrape again, starting at the first scraped link
        if (shouldBeVerbose) serverLogger.log('Sleeping thread for: ${this.crawlSleepTime.inMilliseconds} milliseconds.');
        sleep(this.crawlSleepTime);

        this.dispatchCrawl(this.crawlList.removeAt(0));
      }
    });

    return this.controller.stream;
  }

  /**
   * Traverse the DOM for links, and add them to the queue or already scraped list.
   */
  Future<Null> _parseForLinks() async {
    try {
      if (shouldBeVerbose) serverLogger.log('WebCrawler._parseForLinks()');

      // Fetch the page Document
      final Document document = await this._fetchPageDom();

      if (shouldBeVerbose) serverLogger.log('completed this._fetchPageDom()');

      List<Element> anchors = document.querySelectorAll('a'); // Get all of the link elements from the page
      Uri currentUri; // Will soon hold the current page's URI

      // Mark that this page has been scraped
      if (document.querySelector('link[rel="canonical"]') != null) { // Use the canonical if possible
        String _canonicalUrl = document.querySelector('link[rel="canonical"]').attributes['href'];

        if (_canonicalUrl.startsWith('http') == false) {
          final Uri _thisPageUri = Uri.parse(Uri.encodeFull(this.currentUrlToScrape));
          _canonicalUrl = _thisPageUri.origin + _canonicalUrl;
        }

        currentUri = Uri.parse(Uri.encodeFull(_canonicalUrl));
      } else { // Otherwise, use the url provided
        currentUri = Uri.parse(Uri.encodeFull(this.currentUrlToScrape));
      }

      // Add the current open page's URL to the "already scraped" list
      this.alreadyScrapedUrls.add(currentUri.toString());

      // Loop through each of the scraped anchor tags
      anchors.forEach((final Element link) {
        try {
          // Get the link text
          String linkHref = link.attributes['href'];

          if (linkHref == null) {
            return;
          }

          linkHref = linkHref.trim();

          // Only test the urls that are outbound or relative (no "Javascript: void();" urls)
          if (linkHref.startsWith('http://') ||
              linkHref.startsWith('https://') ||
              linkHref.startsWith('/'))
          {
            // If the url doesn't start with http (e.g. relative URL), then add the origin from the open page
            if (linkHref.startsWith('http') == false && currentUri.toString().startsWith('http')) {
              linkHref = currentUri.origin + linkHref;
            }

            // If the origin is the same as the opened page, is not in crawlList, and is not in alreadyCrawledList,
            // then add it to the next run's crawl list
            if (currentUri.origin == Uri.parse(Uri.encodeFull(linkHref)).origin &&
                this.crawlList.contains(linkHref) == false &&
                this.alreadyScrapedUrls.contains(linkHref) == false)
            {
              this.crawlList.add(linkHref);
            }
          }
        } catch (err) {
          serverLogger.error(err);
        }
      });
    } catch (err) {
      serverLogger.error(err);
    }
  }

  /**
   * Convert the fetched response String to a Document Object Model (DOM).
   */
  Future<Document> _fetchPageDom() async {
    try {
      if (shouldBeVerbose) serverLogger.log('WebCrawler._fetchPageDom()');

      final String pageContents = await this._fetchPageContents();
      if (shouldBeVerbose) serverLogger.log('completed this._fetchPageContents()');

      return parse(pageContents);
    } catch (err) {
      serverLogger.error(err);
    }
  }

  /**
   * Make the Http Request and decode the response for the provided URL.
   */
  Future<String> _fetchPageContents() {
    if (shouldBeVerbose) {
      serverLogger.log('WebCrawler._fetchPageContents()');
      serverLogger.log('Fetching page contents for ${this.currentUrlToScrape}');
    }

    final Completer completer = new Completer();
    final HttpClient httpClient = new HttpClient();
    final Uri uri = Uri.parse(Uri.encodeFull(this.currentUrlToScrape));
    bool hasAlreadyBeenAddedToErrList = false;

    httpClient.getUrl(uri).then((final HttpClientRequest httpClientRequest) {
      httpClientRequest.headers.add('user-agent', 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)');

      return httpClientRequest.close();
    })
    .then((final HttpClientResponse httpClientResponse) {
      decodeHttpClientResponse(httpClientResponse).then(
          completer.complete
      );
    }).catchError((err) {
      print('!!!!!!!!!!!!!!!!');

      if (err is BlankHttpClientResponseException) {
        print(err);

        if (hasAlreadyBeenAddedToErrList == false) {
          this.erredScrapedUrls.add(uri.toString());
          hasAlreadyBeenAddedToErrList = true;
        }

        completer.completeError(err);
        return;
      } else if (err is HttpException) {
        serverLogger.error(err);
        // Handle it some other way, such as retrying
        completer.completeError(err);
        return;
      }

      throw err;
    });

    return completer.future;
  }
}

/**
 * Convert the raw [HttpClientResponse] into a UTF-8 String.
 */
Future<String> decodeHttpClientResponse(final HttpClientResponse httpClientResponse) {
  //serverLogger.log('decodeHttpClientResponse(HttpClientResponse)');

  final Completer<String> completer = new Completer<String>();
  final StringBuffer strBuffer = new StringBuffer();
  Codec codecType = UTF8;

  if (httpClientResponse == null) {
    throw new BlankHttpClientResponseException('The response from the request being decoded returned an invalid [null] value.');
  }

  // Is there a specified charset in the header
  if (httpClientResponse.headers['Content-Type'] != null) {
    // If the value is not UTF-8, and in this case ISO-8859-1, then set the decoder to be that type
    if (httpClientResponse.headers['Content-Type'].join().toLowerCase().contains('charset=ISO-8859-1')) {
      codecType = LATIN1;
    }
  }

  httpClientResponse.transform(codecType.decoder).listen((final dynamic contents) {
    strBuffer.write(contents);
  }, onDone: () {
    completer.complete(strBuffer.toString());
  }, onError: (err) {
    serverLogger.error(err);
    completer.completeError(err);
  });

  return completer.future;
}

class BlankHttpClientResponseException implements Exception {
  final String message;

  BlankHttpClientResponseException([final String this.message]);
}