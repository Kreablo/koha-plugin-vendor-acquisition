use ExtUtils::MakeMaker;


WriteMakefile(
    NAME            => 'Koha::Plugin::AdlibrisAcquisition',
    VERSION_FROM    => 'src/Koha/Plugin/AdlibrisAcquisition.pm',
    NO_MYMETA       => 1
);

package MY;

sub dist {
    my $self = shift;
    my $text = $self->SUPER::dist(@_);

    $text .= <<'KPZ';

kpzdist: $(DISTVNAME).kpz

$(DISTVNAME).kpz: distdir
	rm -f ../../$(DISTVNAME).kpz
	cd $(DISTVNAME)/src && zip -r ../../$(DISTVNAME).kpz Koha/

.PHONY: kpzdist

KPZ
}
