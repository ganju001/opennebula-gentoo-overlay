# Copyright 1999-2016 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI=6
USE_RUBY="ruby24 ruby25 ruby26"

inherit user eutils multilib ruby-ng systemd git-r3

MY_P="opennebula-${PV/_/-}"

DESCRIPTION="OpenNebula Virtual Infrastructure Engine"
HOMEPAGE="http://www.opennebula.org/"
#SRC_URI="http://downloads.opennebula.org/packages/${PN}-${PV}/${PN}-${PV}.tar.gz"
EGIT_REPO_URI="https://github.com/OpenNebula/one.git"
EGIT_COMMIT="release-${PV}"
EGIT_CHECKOUT_DIR=${WORKDIR}/${P}

LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS="~amd64"
IUSE="qemu +mysql xen sqlite +extras systemd sunstone man"

RDEPEND=">=dev-libs/xmlrpc-c-1.18.02[abyss,cxx,threads]
	dev-lang/ruby
	extras? ( dev-libs/openssl
		dev-ruby/libxml
		net-misc/curl
		dev-libs/libxslt
		dev-libs/expat
		dev-ruby/uuidtools
		dev-ruby/amazon-ec2
		dev-ruby/webmock
		dev-ruby/mysql
		dev-ruby/mysql2
		dev-ruby/parse-cron
		dev-ruby/sequel
		dev-ruby/treetop
		dev-ruby/xml-simple
		dev-ruby/zendesk_api
		dev-libs/log4cpp )
	mysql? ( virtual/mysql )
	dev-db/sqlite
	net-misc/openssh
	net-libs/libvncserver
	|| ( app-cdr/cdrkit app-cdr/cdrtools )
	sqlite? ( dev-ruby/sqlite3 )
	qemu? ( app-emulation/libvirt[libvirtd,qemu] )
	xen? ( app-emulation/xen-tools )"
DEPEND="${RDEPEND}
	>=dev-util/scons-1.2.0-r1
	app-text/ronn
	dev-ruby/nokogiri"

# make sure no eclass is running tests
RESTRICT="test"

S="${WORKDIR}/${PN}-${PV}"

ONEUSER="oneadmin"
ONEGROUP="oneadmin"

pkg_setup () {
	enewgroup ${ONEGROUP}
	enewuser ${ONEUSER} -1 /bin/bash /var/lib/one ${ONEGROUP}
}

src_unpack() {
	git-r3_src_unpack
	cd ${S}
	ls -la
	cp "${FILESDIR}/${PV}/SConstruct.man" "share/man/SConstruct"
	cd src/sunstone/public
	mkdir patches
	rm -rf node_modules
	rm -rf dist	

	epatch "${FILESDIR}/${PV}/package.json.diff"
	epatch "${FILESDIR}/${PV}/sunstone_public_build.sh.diff"
	export PATH=$PATH:${S}/src/sunstone/public/node_modules/.bin
	sh build.sh -d
	npm install
	bower install
	DIR=${PWD}
        cd bower_components/no-vnc/
        rm -rf node_modules
        npm intall
        cd ${DIR}  
	cd ../../..
}

src_prepare() {
	default

	sed -i -e 's|chmod|true|' install.sh || die "sed failed"

	epatch "${FILESDIR}/${PV}/SConstruct.diff"
 	epatch "${FILESDIR}/${PV}/websocket.py.diff"
	epatch "${FILESDIR}/${PV}/websocketproxy.py.diff"
	epatch "${FILESDIR}/${PV}/OpenNebulaVNC.rb.diff"
	cp "${FILESDIR}/${PV}/SConstruct.man" "${S}/share/man/SConstruct"
	eapply_user
}

src_configure() {
	:
}

src_compile() {

	local myconf
	use extras && myconf+="new_xmlrpc=yes "
	use mysql && myconf+="mysql=yes " || myconf+="mysql=no "
	use sunstone && myconf+="sunstone=yes "
	use man && myconf+="manpages=yes "

	export PATH=$PATH:${S}/src/sunstone/public/node_modules/.bin

	python2.7 $(which scons) \
		${myconf} \
		$(sed -r 's/.*(-j\s*|--jobs=)([0-9]+).*/-j\2/' <<< ${MAKEOPTS}) \
		|| die "building ${PN} failed"
}

src_install() {
	DESTDIR=${T} ./install.sh -u ${ONEUSER} -g ${ONEGROUP} || die "install failed"

	cd "${T}"

	# installing things for real
	dobin bin/*

	keepdir /var/{lib,run}/${PN} || die "keepdir failed"

	dodir /usr/$(get_libdir)/one
	dodir /var/lock/one
	dodir /var/log/one
	dodir /var/lib/one
	dodir /var/run/one
	dodir /var/tmp/one
	# we have to preserve the executable bits
	cp -a lib/* "${D}/usr/$(get_libdir)/one/" || die "copying lib files failed"
	ln -s "${D}/usr/$(get_libdir)/one/" "${D}/usr/lib/one/" || die "creating symlink failed"

	insinto /usr/share/doc/${PF}
	doins -r share/examples

	dodir /var/lib/one
	dodir /var/lib/one/vms
	dodir /usr/share/one
	dodir /etc/tmpfiles.d
	# we have to preserve the executable bits
	cp -a var/remotes "${D}/var/lib/one/" || die "copying remotes failed"
	cp -a var/sunstone "${D}/var/lib/one/" || die "copying sunstone failed"
	cp -a var/datastores "${D}/var/lib/one/" || die "copying datastores failed"
	cp -a share/* "${D}/usr/share/one/" || die "copying share failed"

	doenvd "${FILESDIR}/99one"

	newinitd "${FILESDIR}/opennebula.initd" opennebula
	newinitd "${FILESDIR}/sunstone-server.initd" sunstone-server
	newinitd "${FILESDIR}/oneflow-server.initd" oneflow-server
	newconfd "${FILESDIR}/opennebula.confd" opennebula
	newconfd "${FILESDIR}/sunstone-server.confd" sunstone-server
	newconfd "${FILESDIR}/oneflow-server.confd" oneflow-server

	use systemd && systemd_dounit "${FILESDIR}"/opennebula{,-sunstone,-econe,-oneflow,-onegate}.service

	insinto /etc/one
	insopts -m 0640
	doins -r etc/*
	doins "${FILESDIR}/one_auth"

	insinto /etc/tmpfiles.d
	doins "${FILESDIR}/tmpfilesd.opennebula.conf"

}

pkg_postinst() {


	chown -R ${ONEUSER}:${ONEGROUP} ${ROOT}var/{lock,lib,log,run,tmp}/one
	chown -R ${ONEUSER}:${ONEGROUP} ${ROOT}usr/share/one
	chown -R ${ONEUSER}:${ONEGROUP} ${ROOT}etc/one
	chown -R ${ONEUSER}:${ONEGROUP} ${ROOT}usr/lib/one

	local onedir="${EROOT}var/lib/one"
	if [ ! -d "${onedir}/.ssh" ] ; then
		einfo "Generating ssh-key..."
		umask 0027 || die "setting umask failed"
		mkdir "${onedir}/.ssh" || die "creating ssh directory failed"
		ssh-keygen -q -t dsa -N "" -f "${onedir}/.ssh/id_dsa" || die "ssh-keygen failed"
		cat > "${onedir}/.ssh/config" <<EOF
UserKnownHostsFile /dev/null
Host *
    StrictHostKeyChecking no
EOF
		cat "${onedir}/.ssh/id_dsa.pub"  >> "${onedir}/.ssh/authorized_keys" || die "adding key failed"
		chown -R ${ONEUSER}:${ONEGROUP} "${onedir}/.ssh" || die "changing owner failed"
	fi

	if use qemu ; then
		elog "Make sure that the user ${ONEUSER} has access to the libvirt control socket"
		elog "  /var/run/libvirt/libvirt-sock"
		elog "You can easily check this by executing the following command as ${ONEUSER} user"
		elog "  virsh -c qemu:///system nodeinfo"
		elog "If not using using policykit in libvirt, the file you should take a look at is:"
		elog "  /etc/libvirt/libvirtd.conf (look for the unix_sock_*_perms parameters)"
		elog "Failure to do so may lead to nodes hanging in PENDING state forever without further notice."
		echo ""
		elog "Should a node hang in PENDING state even with correct permissions, try the following to get more information."
		elog "In /tmp/one-im execute the following command for the biggest one_im-* file:"
		elog "  ruby -wd one_im-???"
		echo ""
		elog "OpenNebula doesn't allow you to specify the disc format."
		elog "Unfortunately the default in libvirt is not to guess and"
		elog "it therefores assumes a 'raw' format when using qemu/kvm."
		elog "Set 'allow_disk_format_probing = 0' in /etc/libvirt/qemu.conf"
		elog "to work around this until OpenNebula fixes it."
	fi

	elog "If you wish to use the sunstone server, please issue the command"
	#elog "/usr/share/one/install_gems as oneadmin user"
	elog "gem install sequel thin json rack sinatra builder treetop zendesk_api mysql parse-cron"
}

