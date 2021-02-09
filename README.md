# Vendor Acquisition Plugin for Koha

This plugin facilitates receiving acquisition orders from a vendor,
where the order is initiated at the vendor's site.  The vendor must
implement the protocol of this plugin.

## Installation

Make sure plugins are enabled (<enable_plugins>1</enable_plugins> in
/yazgfc/config of koha-conf.xml) and that the koha-instance have full
permissions on the directory specified by the element <pluginsdir/> in
koha-conf.xml.

* Go to Koha administration -> Manage plugins.
* Click on "upload plugin" and upload the kpz-file.

## Configuration

The plugin can be configured with the parameters described below.  At
least a vendor mapping must exist for the vendor where the plugin will
be used.

There must also exist at least one budget in the acquisition module.

Click "save configuration" after changing the configuration/.

### Record match rule

A record match rule can be selected in order to avoid reimporting
already existing records.  New record matching rules can be configured
under Kuha administration -> Record matching rules.

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
