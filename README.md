# Feedro

## Description

Feedro is a dead-simple service that allow clients to:

1. create new feeds
2. delete previously-created feeds
3. post new item to a previously-created feed
4. remove all items from the given feed
5. Retrieve the feed in the format of JSON Feed or others.

## API

### 1. Feed creation

Feed creation requires 3 pieces of information, a feed title, a description, and a "proof".
Such as:

    POST /feed/
    {
        title: "Foobar",
        description: "A feed about foobar",
        proof: [1568462482, 1559113, "feedf5dd6aac2f6c0b0bbd01f7301d8e6b4b8a26"]
    }

The values inside the "proof" array are: a timestamp, a prime number, and a sha1 of:

    title ~ "\n" ~ description ~ "\n" ~ timestamp ~ "\n" ~ prime_number

The "~" above means string concatenation. Both timestamp and the prime_number
are represented in decimal positive integers. Timestamp should be in the range
of 3600s ago to present, relative to the server time. Feedro server would
create the feed only if the proof is valid.

Upon creation failures, the server returns 500 status code, with

a "error" message describing :

    {
        "error": "An error occured."
    }
    
The response upon successful ceration, shall  contain the an identifier,
as well as a token:

    {
        "identifier": "82253db2-d6e2-11e9-ae6d-48d705cb7aad",
        "token": "ZHTQ1e5J0uNGw3Gynp-BcWmaY24"
    }

Both piece of information must be preserved by the client side.

Identifier is used in the URL to append a new item to a feed.  Token must be
provided for all other requests in the HTTP authentication header as a "Bearer
token". With the example above, the line of such header would be this:

    Authentication: Bearer ZHTQ1e5J0uNGw3Gynp-BcWmaY24

POST / PUT requests without a matching token are simply ignored and responded
with 401 status code.

### 2. Feed deletion

To delete a feed, send a DELETE request with bearer token.

    DELETE /feed/:identifier
    Authentication: Bearer :token

### 3. Adding new items

To add a new item into a feed, send a POST request with bearer token.

    POST /feed/:identifier/items
    Authentication: Bearer :token
    {
        "id": "xxx",
        "title": "xxx",
        "url": "xxx",
        "content_text": "xxx"
        "content_html": "xxx"
    }

The payload of this request is modeled as the "Items" section in the spec of jsonfeed:

    https://jsonfeed.org/version/1

### 4. Deleting items

To delete items from a feed, send the following DELETE request

    DELETE /feed/:identifier/items
    Authentication: Bearer :token

This removes all items from the feed.
    
### 5. Retrieving feed

To retrieve the feed, send the following GET request:

    GET /feed/:identifier.json

The feed returns in JSON Feed format. Alternatively,
RSS format and Atom format of the identical feed can be retrieved,
by changing the ".json" part of the url to ".rss", or ".atom"

    GET /feed/:identifier.rss
    GET /feed/:identifier.atom
