# cometclient
Objective-C comet client using the Bayeux protocol

This is an updated version of the original ddunkin/cometclient that supports a set of new features

The original intended use case of this library is for an iOS application that uses JSON RESTful web services to retrieve entities and then is interested in the changes to those entities.

The simplest method uses a naming scheme for the entities that matches the channel of the updates to those same entities. 
(e.g. If GET /person/1 is the RESTful URL, /person/1 would be be the channel that you retrieve updates to that person from) 
They should share the same entity schema for the web service as the cometd service so that they can be treated the same on the client side.

New Features:

1. Updated for ARC with all warnings fixed
2. Additional delegates on success/failure of subscriptions and message publication
3. Added support for block callbacks on success/failure of subscriptions and message publication
4. Persistent subscriptions
5. Updated 
5. Replace NSURLConnection with NSURLSession
6  Added WebSocket support through SocketRocket.
   
   Previously when a client timeout occured (i.e. when it had been more than x seconds between queries where x is defined as the CometD timeout on the server), all subscription information was lost.  For mobile devices where momentary disconnections are not uncommon, this was extremely problematic.
   
   To allevaite the problem, subscription information is now maintained and resubscribed when a clientout timeout occurs.  
   
   Additionally subscriptions can also be made persistent between intentional disconnections from the CometD server (e.g. when the app goes into the background).
   This means that the disconnect selector on the DDCometClient instance should be called in
   
   
