#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Image::ExifTool;
use CGI;
use File::Copy;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Log only to file
$imagelol->enable_silent_logging();

# Log
sub log_it{
	$imagelol->log_it("www-image", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("www-image", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("www-image", "@_");
}

# print image
sub show_image{
	my $img_filename = shift;
	
	# Fetch JPG from RAW
	my $exif_tags = Image::ExifTool::ImageInfo($img_filename, { PrintConv => 0 }, 'PreviewImage');
	
	# Exit if error
	print_error() if($exif_tags->{'Error'});
	print_error() unless defined($exif_tags->{'PreviewImage'});

	# Fetch JPG
	my $jpg_from_raw = $exif_tags->{'PreviewImage'};
	$jpg_from_raw = $$jpg_from_raw if ref($jpg_from_raw);
	
	# my $JPG_FILE;
	# my $jpg_filename = "/srv/bilder/tmp/testing.jpg";
	# open(JPG_FILE,">$jpg_filename") or print("Error creating $jpg_filename\n"), return 0;
	#     	binmode(JPG_FILE);
	#     	my $err;
	# 
	#     	print JPG_FILE $jpg_from_raw or $err = 1;
	# close(JPG_FILE) or $err = 1;
	#     	if ($err) {
	#       		unlink $jpg_filename; # remove the bad file
	# 	print_error();
	#     	}
	
	# this must be done for windows
	binmode STDOUT;
	
	# flush headers
	$|=1;
	
	# print the image
	print "Content-type: image/jpeg\n\n";
	#copy $jpg_filename, \*STDOUT;
	print \*STDOUT $jpg_from_raw;
}

# print if error
sub print_error{
	print "Content-Type: text/html\n\n";
	print "Something went wrong. No kitties were harmed.\n";
	exit 1;
}

# Let's start...
my $time_start = time();

my $image_name = "/srv/bilder/import/IMG_0420.CR2";

show_image($image_name);

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");



