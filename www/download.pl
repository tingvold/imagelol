#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use File::Basename;
use Encode;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Log
sub log_it{
	$imagelol->log_it("album-download", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("album-download", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("album-download", "@_");
	return 0;
}

# ZIP an entire album on-the-fly
sub zip_album{
	my $path = "/srv/bilder/arkiv/preview/6D/2014/06/19/IMG_8873.jpg";
	my $filename = "test.zip";
	my $zip = Archive::Zip->new();
	$zip->addTree( $path, '' );

	# set binmode
	binmode STDOUT;
	
	# flush headers
	$|=1;
	
	# header
	#Content-type: application/zip\n"
	#"Content-Disposition: attachment; filename=\"$filename\"\n\n";
		
	# sendt to browser
	$zip->writeToFileHandle( \*STDOUT, 0 );
}


# Let's start...
#my $time_start = time();
#$imagelol->connect();


zip_album();



#$imagelol->disconnect();

