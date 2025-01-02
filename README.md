# Vendor Acquisition Plugin for Koha

This plugin facilitates receiving acquisition orders from a vendor,
where the order is initiated at the vendor's site.  The vendor must
implement the protocol of this plugin.

## API specification

The vendor must implement the following API for sending order data to Koha:

https://docs.google.com/document/d/1aGHbyR0xz4E1JKO_CIg6drVVznRPTvXzt9Zwqyobiws/edit?usp=sharing


## Installation

Make sure plugins are enabled (&lt;enable\_plugins&gt;1&lt;/enable\_plugins&gt; in
/yazgfc/config of koha-conf.xml) and that the koha-instance have full
permissions on the directory specified by the element &lt;pluginsdir/&gt; in
koha-conf.xml.

* Go to Koha administration -> Manage plugins.
* Click on "upload plugin" and upload the kpz-file.

## Upgrade

**Important when upgrading to Koha 24.05 or newer**: The new CSRF
protection does not allow POST-requests without CSRF-token. We are
currently reworking the protocol to accomodate for this, but for now a
patch for Koha is required for using this plugin:

```
diff --git a/Koha/Middleware/CSRF.pm b/Koha/Middleware/CSRF.pm
index 58e75c948e..690e1a13f4 100644
--- a/Koha/Middleware/CSRF.pm
+++ b/Koha/Middleware/CSRF.pm
@@ -63,8 +63,11 @@ sub call {
             $error = sprintf "Programming error - op '%s' must start with 'cud-' for %s %s (referer: %s)", $original_op,
                 $request_method, $uri, $referer;
         } elsif ( !$csrf_token ) {
-            $error = sprintf "Programming error - No CSRF token passed for %s %s (referer: %s)", $request_method,
-                $uri, $referer;
+            my $u0 = URI->new($uri);
+            unless ($u0->path =~ m|/intranet/plugins/run.pl$| && $req->param('method') eq 'vendor_order_receive') {
+                $error = sprintf "Programming error - No CSRF token passed for %s %s (referer: %s)", $request_method,
+                    $uri, $referer;
+            }
         } else {
             unless (
                 Koha::Token->new->check_csrf(
```

(Before Koha version 24.05 Plack could not reload perl-packages
dynamically and needs to be restarted, so shell access to the Koha
server is needed to complete the upgrade process.)

* Go to Koha administration -> Manage plugins.
* Click on "upload plugin" and upload the kpz-file corresponding to a
  newer version of the plugin.
* Restart plack, unless server is configured to automatically reload
  plack after plugin upload.

## Security token

As protection against cross site request forgery attacks, the plugin
generates a random token upon installation.  This token is part of the
URL that needs to be communicated to the vendor.  Note that if the
plugin is reinstalled, this token may be regenerated and then a new
link needs to be communicated to the vendor.

**Note that the security token currently needs to be added to the form
data by the vendor, so you may need to communicate this token
separately to the vendor.**

## Configuration

The plugin can be configured with the parameters described below.  At
least a vendor mapping must exist for the vendor where the plugin will
be used.

There must also exist at least one budget in the acquisition module.

Click "save configuration" after changing the configuration/.

### Record match rule

A record match rule can be selected in order to avoid reimporting
already existing records.  New record matching rules can be configured
under Koha administration -> Record matching rules.

When receiving an order, the match with highest score, if any matches,
will be selected by default.  The user will be able to choose a
match among the highest scored matches, or choose to create a new
record even if there are matches.

### Demo mode

This enables a form for submitting test data.  Do not enable this on a
production system, as it might cause confusion in the event a user
lands on the receieve order page after logging in with single-sign-on.


### Vendor mappings

The Vendor identifies itself by a string in the posted data.  This
must be matched with a vendor in the acquisition module.  The vendor
identity string must match exactly the string the vendor use.  The
vendor in Koha can be selected from the list of existing vendors in
the acquisition module.


To add a vendor in Koha go to Acquisitions and click "New vendor".

### Default item values

New items will be created according to the paramaeter "Quantity" sent
by the vendor.  The fields of the item can be prefilled with default
values according to this configuration.  The user will also be able to
edit these field as the order is received.

The customer number must match the identity string that the vendor use
to identify the library.  You can use * to apply the same default
rules without giving an explicit customer number.

## Permissions

This plugin is only accessible to users that have staff access.  On top of that:

- to receive orders a user must have the permission **plugins/vendor_order_receive**,
- to install or upgrade the plugin the user needs the permission **plugins/manage**,
- to configure the plugin the user needs the permission **plugins/configure**.

## Building

The module can be built using these commands:

    perl Makefile.PL
    make kpzdist

## Translation

Copy the file 'src/Koha/Plugin/VendorAcquisition/i18n/default.inc' to
a file to a new file in the same directory where the filename matches
the language code of the target language with the filename extension
'.inc'. For instance
'src/Koha/Plugin/VendorAcquisition/i18n/sv-SE.inc'.  Edit the new file
to translate the texts within the quotation marks.
