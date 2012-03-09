!
! Copyright (C) 2008-2012 Georgy Samsonidze
!
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
! Converts the output files produced by pw.x to the input files for BerkeleyGW.
!
!-------------------------------------------------------------------------------
!
! BerkeleyGW, Copyright (c) 2011, The Regents of the University of
! California, through Lawrence Berkeley National Laboratory (subject to
! receipt of any required approvals from the U.S. Dept. of Energy).
! All rights reserved.
!
! Redistribution and use in source and binary forms, with or without
! modification, are permitted provided that the following conditions are
! met:
!
! (1) Redistributions of source code must retain the above copyright
! notice, this list of conditions and the following disclaimer.
!
! (2) Redistributions in binary form must reproduce the above copyright
! notice, this list of conditions and the following disclaimer in the
! documentation and/or other materials provided with the distribution.
!
! (3) Neither the name of the University of California, Lawrence
! Berkeley National Laboratory, U.S. Dept. of Energy nor the names of
! its contributors may be used to endorse or promote products derived
! from this software without specific prior written permission.
!
! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
! "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
! LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
! A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
! OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
! SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
! LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
! DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
! THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
! (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
!
! You are under no obligation whatsoever to provide any bug fixes,
! patches, or upgrades to the features, functionality or performance of
! the source code ("Enhancements") to anyone; however, if you choose to
! make your Enhancements available either publicly, or directly to
! Lawrence Berkeley National Laboratory, without imposing a separate
! written license agreement for such Enhancements, then you hereby grant
! the following license: a  non-exclusive, royalty-free perpetual
! license to install, use, modify, prepare derivative works, incorporate
! into other computer software, distribute, and sublicense such
! enhancements or derivative works thereof, in binary and source code
! form.
!
!-------------------------------------------------------------------------------
!
!   pw2bgw subroutines:
!
!   write_wfng  - generates complex wavefunctions in G-space (normalized to 1)
!   real_wfng   - constructs real wavefunctions by applying the Gram-Schmidt
!                 process (called from write_wfng)
!   write_rhog  - generates complex charge density in G-space
!                 (units of the number of electronic states per unit cell)
!   write_vxcg  - generates complex exchange-correlation potential in G-space
!                 (units of Rydberg) [only local part of Vxc]
!   write_vxc0  - prints complex exchange-correlation potential at G=0
!                 (units of eV) [only local part of Vxc]
!   write_vxc_r - calculates matrix elements of exchange-correlation potential
!                 in R-space (units of eV) [only local part of Vxc]
!   write_vxc_g - calculates matrix elements of exchange-correlation potential
!                 in G-space (units of eV) [supports non-local Vxc]
!   write_vnlg  - generates Kleinman-Bylander projectors in G-space
!                 (units of Rydberg)
!   check_inversion - checks whether real/complex version is appropriate
!
!   Quantum ESPRESSO stores the wavefunctions in is-ik-ib-ig order
!   BerkeleyGW stores the wavefunctions in ik-ib-is-ig order
!   the outer loop is over is(QE)/ik(BGW) and the inner loop is over ig
!   ik = k-point index, is = spin index, ib = band index, ig = G-vector index
!
!   write_wfng reverts the order of is and ik using smap and kmap arrays,
!   distributes wavefunctions over processors by ig (either real case or
!   spin-polarized case), calls real_wfng that applies the Gram-Schmidt
!   process (real case), reverts the order of is and ib (spin-polarized
!   case), and writes wavefunctions to disk
!
!-------------------------------------------------------------------------------

PROGRAM pw2bgw

  USE environment, ONLY : environment_start, environment_end
  USE control_flags, ONLY : gamma_only
  USE io_files, ONLY : prefix, tmp_dir, outdir
  USE io_global, ONLY : ionode, ionode_id
  USE kinds, ONLY : DP
  USE mp, ONLY : mp_bcast
  USE mp_global, ONLY : mp_startup
  USE uspp, ONLY : okvan
  USE paw_variables, ONLY : okpaw
  USE lsda_mod, ONLY : nspin

  IMPLICIT NONE

  character(len=6) :: codename = 'PW2BGW'

  integer :: real_or_complex
  character ( len = 9 ) :: symm_type
  logical :: wfng_flag
  character ( len = 256 ) :: wfng_file
  logical :: wfng_kgrid
  integer :: wfng_nk1
  integer :: wfng_nk2
  integer :: wfng_nk3
  real (DP) :: wfng_dk1
  real (DP) :: wfng_dk2
  real (DP) :: wfng_dk3
  logical :: wfng_occupation
  integer :: wfng_nvmin
  integer :: wfng_nvmax
  logical :: rhog_flag
  character ( len = 256 ) :: rhog_file
  logical :: vxcg_flag
  character ( len = 256 ) :: vxcg_file
  logical :: vxc0_flag
  character ( len = 256 ) :: vxc0_file
  logical :: vxc_flag
  character ( len = 256 ) :: vxc_file
  character :: vxc_integral
  integer :: vxc_diag_nmin
  integer :: vxc_diag_nmax
  integer :: vxc_offdiag_nmin
  integer :: vxc_offdiag_nmax
  character ( len = 20 ) :: input_dft
  logical :: exx_flag
  logical :: vnlg_flag
  character ( len = 256 ) :: vnlg_file

  NAMELIST / input_pw2bgw / prefix, outdir, &
    real_or_complex, symm_type, wfng_flag, wfng_file, wfng_kgrid, &
    wfng_nk1, wfng_nk2, wfng_nk3, wfng_dk1, wfng_dk2, wfng_dk3, &
    wfng_occupation, wfng_nvmin, wfng_nvmax, rhog_flag, rhog_file, &
    vxcg_flag, vxcg_file, vxc0_flag, vxc0_file, vxc_flag, &
    vxc_file, vxc_integral, vxc_diag_nmin, vxc_diag_nmax, &
    vxc_offdiag_nmin, vxc_offdiag_nmax, input_dft, exx_flag, &
    vnlg_flag, vnlg_file

  integer :: ii, ios
  character ( len = 256 ) :: output_file_name

  character (len=256), external :: trimcheck
  character (len=1), external :: lowercase

#ifdef __PARA
  CALL mp_startup ( )
#endif
  CALL environment_start ( codename )

  prefix = 'prefix'
  CALL get_env ( 'ESPRESSO_TMPDIR', outdir )
  IF ( TRIM ( outdir ) == ' ' ) outdir = './'
  real_or_complex = 2
  symm_type = 'cubic'
  wfng_flag = .FALSE.
  wfng_file = 'WFN'
  wfng_kgrid = .FALSE.
  wfng_nk1 = 0
  wfng_nk2 = 0
  wfng_nk3 = 0
  wfng_dk1 = 0.0D0
  wfng_dk2 = 0.0D0
  wfng_dk3 = 0.0D0
  wfng_occupation = .FALSE.
  wfng_nvmin = 0
  wfng_nvmax = 0
  rhog_flag = .FALSE.
  rhog_file = 'RHO'
  vxcg_flag = .FALSE.
  vxcg_file = 'VXC'
  vxc0_flag = .FALSE.
  vxc0_file = 'vxc0.dat'
  vxc_flag = .FALSE.
  vxc_file = 'vxc.dat'
  vxc_integral = 'g'
  vxc_diag_nmin = 0
  vxc_diag_nmax = 0
  vxc_offdiag_nmin = 0
  vxc_offdiag_nmax = 0
  input_dft = 'sla+pz'
  exx_flag = .FALSE.
  vnlg_flag = .FALSE.
  vnlg_file = 'VNL'

  IF ( ionode ) THEN
    CALL input_from_file ( )
    READ ( 5, input_pw2bgw, iostat = ios )
    IF ( ios /= 0 ) CALL errore ( codename, 'input_pw2bgw', abs ( ios ) )

    DO ii = 1, LEN_TRIM (symm_type)
      symm_type(ii:ii) = lowercase (symm_type(ii:ii))
    END DO
    DO ii = 1, LEN_TRIM (vxc_integral)
      vxc_integral(ii:ii) = lowercase (vxc_integral(ii:ii))
    END DO

    IF ( real_or_complex /= 1 .AND. real_or_complex /= 2 ) &
      CALL errore ( codename, 'real_or_complex', 1 )
    IF ( symm_type /= 'cubic' .AND. symm_type /= 'hexagonal' ) &
      CALL errore ( codename, 'symm_type', 1 )
    IF ( vxc_integral /= 'r' .AND. vxc_integral /= 'g' ) &
      CALL errore ( codename, 'vxc_integral', 1 )
  ENDIF

  tmp_dir = trimcheck ( outdir )
  CALL mp_bcast ( outdir, ionode_id )
  CALL mp_bcast ( tmp_dir, ionode_id )
  CALL mp_bcast ( prefix, ionode_id )
  CALL mp_bcast ( real_or_complex, ionode_id )
  CALL mp_bcast ( symm_type, ionode_id )
  CALL mp_bcast ( wfng_flag, ionode_id )
  CALL mp_bcast ( wfng_file, ionode_id )
  CALL mp_bcast ( wfng_kgrid, ionode_id )
  CALL mp_bcast ( wfng_nk1, ionode_id )
  CALL mp_bcast ( wfng_nk2, ionode_id )
  CALL mp_bcast ( wfng_nk3, ionode_id )
  CALL mp_bcast ( wfng_dk1, ionode_id )
  CALL mp_bcast ( wfng_dk2, ionode_id )
  CALL mp_bcast ( wfng_dk3, ionode_id )
  CALL mp_bcast ( wfng_occupation, ionode_id )
  CALL mp_bcast ( wfng_nvmin, ionode_id )
  CALL mp_bcast ( wfng_nvmax, ionode_id )
  CALL mp_bcast ( rhog_flag, ionode_id )
  CALL mp_bcast ( rhog_file, ionode_id )
  CALL mp_bcast ( vxcg_flag, ionode_id )
  CALL mp_bcast ( vxcg_file, ionode_id )
  CALL mp_bcast ( vxc0_flag, ionode_id )
  CALL mp_bcast ( vxc0_file, ionode_id )
  CALL mp_bcast ( vxc_flag, ionode_id )
  CALL mp_bcast ( vxc_integral, ionode_id )
  CALL mp_bcast ( vxc_file, ionode_id )
  CALL mp_bcast ( vxc_diag_nmin, ionode_id )
  CALL mp_bcast ( vxc_diag_nmax, ionode_id )
  CALL mp_bcast ( vxc_offdiag_nmin, ionode_id )
  CALL mp_bcast ( vxc_offdiag_nmax, ionode_id )
  CALL mp_bcast ( input_dft, ionode_id )
  CALL mp_bcast ( exx_flag, ionode_id )
  CALL mp_bcast ( vnlg_flag, ionode_id )
  CALL mp_bcast ( vnlg_file, ionode_id )

  CALL read_file ( )

  if(okvan) call errore ( 'pw2bgw', 'BGW cannot use ultrasoft pseudopotentials.', 3 )
  if(okpaw) call errore ( 'pw2bgw', 'BGW cannot use PAW.', 4 )
  if(gamma_only) call errore ( 'pw2bgw', 'BGW cannot use gamma-only run.', 5 )
  if(nspin == 4) call errore ( 'pw2bgw', 'BGW cannot use spinors.', 6 )

  CALL openfil_pp ( )

  IF ( wfng_flag ) THEN
    output_file_name = TRIM ( outdir ) // '/' // TRIM ( wfng_file )
    IF ( ionode ) WRITE ( 6, '(5x,"call write_wfng")' )
    CALL start_clock ( 'write_wfng' )
    CALL write_wfng ( output_file_name, real_or_complex, symm_type, &
      wfng_kgrid, wfng_nk1, wfng_nk2, wfng_nk3, wfng_dk1, wfng_dk2, &
      wfng_dk3, wfng_occupation, wfng_nvmin, wfng_nvmax )
    CALL stop_clock ( 'write_wfng' )
    IF ( ionode ) WRITE ( 6, '(5x,"done write_wfng",/)' )
  ENDIF

  IF ( rhog_flag ) THEN
    output_file_name = TRIM ( outdir ) // '/' // TRIM ( rhog_file )
    IF ( ionode ) WRITE ( 6, '(5x,"call write_rhog")' )
    CALL start_clock ( 'write_rhog' )
    CALL write_rhog ( output_file_name, real_or_complex, symm_type )
    CALL stop_clock ( 'write_rhog' )
    IF ( ionode ) WRITE ( 6, '(5x,"done write_rhog",/)' )
  ENDIF

  IF ( vxcg_flag ) THEN
    output_file_name = TRIM ( outdir ) // '/' // TRIM ( vxcg_file )
    IF ( ionode ) WRITE ( 6, '(5x,"call write_vxcg")' )
    CALL start_clock ( 'write_vxcg' )
    CALL write_vxcg ( output_file_name, real_or_complex, symm_type, &
      input_dft, exx_flag )
    CALL stop_clock ( 'write_vxcg' )
    IF ( ionode ) WRITE ( 6, '(5x,"done write_vxcg",/)' )
  ENDIF

  IF ( vxc0_flag ) THEN
    output_file_name = TRIM ( outdir ) // '/' // TRIM ( vxc0_file )
    IF ( ionode ) WRITE ( 6, '(5x,"call write_vxc0")' )
    CALL start_clock ( 'write_vxc0' )
    CALL write_vxc0 ( output_file_name, input_dft, exx_flag )
    CALL stop_clock ( 'write_vxc0' )
    IF ( ionode ) WRITE ( 6, '(5x,"done write_vxc0",/)' )
  ENDIF

  IF ( vxc_flag ) THEN
    output_file_name = TRIM ( outdir ) // '/' // TRIM ( vxc_file )
    IF ( vxc_integral .EQ. 'r' ) THEN
      IF ( ionode ) WRITE ( 6, '(5x,"call write_vxc_r")' )
      CALL start_clock ( 'write_vxc_r' )
      CALL write_vxc_r ( output_file_name, &
        vxc_diag_nmin, vxc_diag_nmax, &
        vxc_offdiag_nmin, vxc_offdiag_nmax, &
        input_dft, exx_flag )
      CALL stop_clock ( 'write_vxc_r' )
      IF ( ionode ) WRITE ( 6, '(5x,"done write_vxc_r",/)' )
    ENDIF
    IF ( vxc_integral .EQ. 'g' ) THEN
      IF ( ionode ) WRITE ( 6, '(5x,"call write_vxc_g")' )
      CALL start_clock ( 'write_vxc_g' )
      CALL write_vxc_g ( output_file_name, &
        vxc_diag_nmin, vxc_diag_nmax, &
        vxc_offdiag_nmin, vxc_offdiag_nmax, &
        input_dft, exx_flag )
      CALL stop_clock ( 'write_vxc_g' )
      IF ( ionode ) WRITE ( 6, '(5x,"done write_vxc_g",/)' )
    ENDIF
  ENDIF

  IF ( vnlg_flag ) THEN
    output_file_name = TRIM ( outdir ) // '/' // TRIM ( vnlg_file )
    IF ( ionode ) WRITE ( 6, '(5x,"call write_vnlg")' )
    CALL start_clock ( 'write_vnlg' )
    CALL write_vnlg ( output_file_name, symm_type, wfng_kgrid, wfng_nk1, &
      wfng_nk2, wfng_nk3, wfng_dk1, wfng_dk2, wfng_dk3 )
    CALL stop_clock ( 'write_vnlg' )
    IF ( ionode ) WRITE ( 6, '(5x,"done write_vnlg",/)' )
  ENDIF

  IF ( ionode ) WRITE ( 6, * )
  IF ( wfng_flag ) CALL print_clock ( 'write_wfng' )
  IF ( rhog_flag ) CALL print_clock ( 'write_rhog' )
  IF ( vxcg_flag ) CALL print_clock ( 'write_vxcg' )
  IF ( vxc0_flag ) CALL print_clock ( 'write_vxc0' )
  IF ( vxc_flag ) THEN
    IF ( vxc_integral .EQ. 'r' ) &
      CALL print_clock ( 'write_vxc_r' )
    IF ( vxc_integral .EQ. 'g' ) &
      CALL print_clock ( 'write_vxc_g' )
  ENDIF
  IF ( vnlg_flag ) CALL print_clock ( 'write_vnlg' )
  IF ( wfng_flag .AND. real_or_complex .EQ. 1 ) THEN
    IF ( ionode ) WRITE ( 6, '(/,5x,"Called by write_wfng:")' )
    CALL print_clock ( 'real_wfng' )
  ENDIF

  CALL environment_end ( codename )
  CALL stop_pp ( )

  STOP

END PROGRAM pw2bgw

!-------------------------------------------------------------------------------

SUBROUTINE write_wfng ( output_file_name, real_or_complex, symm_type, &
  wfng_kgrid, wfng_nk1, wfng_nk2, wfng_nk3, wfng_dk1, wfng_dk2, &
  wfng_dk3, wfng_occupation, wfng_nvmin, wfng_nvmax )

  USE cell_base, ONLY : omega, alat, tpiba, tpiba2, at, bg, ibrav
  USE constants, ONLY : pi, tpi, eps6
  USE fft_base, ONLY : dfftp
  USE gvect, ONLY : ngm, ngm_g, ig_l2g, g, mill, ecutrho
  USE io_files, ONLY : iunwfc, nwordwfc
  USE io_global, ONLY : ionode, ionode_id
  USE ions_base, ONLY : nat, atm, ityp, tau
  USE kinds, ONLY : DP
  USE klist, ONLY : xk, wk, ngk, nks, nkstot
  USE lsda_mod, ONLY : nspin, isk
  USE mp, ONLY : mp_sum, mp_max, mp_get, mp_bcast, mp_barrier
  USE mp_global, ONLY : mpime, nproc, world_comm, kunit, me_pool, &
    root_pool, my_pool_id, npool, nproc_pool, intra_pool_comm
  USE mp_wave, ONLY : mergewf
  USE start_k, ONLY : nk1, nk2, nk3, k1, k2, k3
  USE symm_base, ONLY : s, ftau, nsym
  USE wavefunctions_module, ONLY : evc
  USE wvfct, ONLY : npwx, nbnd, npw, et, wg, g2kin, ecutwfc
#ifdef __PARA
  USE parallel_include, ONLY : MPI_DOUBLE_COMPLEX
#endif

  IMPLICIT NONE

  character ( len = 256 ), intent (in) :: output_file_name
  integer, intent (in) :: real_or_complex
  character ( len = 9 ), intent (in) :: symm_type
  logical, intent (in) :: wfng_kgrid
  integer, intent (in) :: wfng_nk1
  integer, intent (in) :: wfng_nk2
  integer, intent (in) :: wfng_nk3
  real (DP), intent (in) :: wfng_dk1
  real (DP), intent (in) :: wfng_dk2
  real (DP), intent (in) :: wfng_dk3
  logical, intent (in) :: wfng_occupation
  integer, intent (in) :: wfng_nvmin
  integer, intent (in) :: wfng_nvmax

  character :: cdate*9, ctime*9, sdate*32, stime*32, stitle*32
  logical :: proc_wf, bad_kgrid
  integer :: u, i, j, k, cell_symmetry, nrecord
  integer :: id, ib, ik, iks, ike, is, ig, ierr
  integer :: nd, ntran, nb, nk_l, nk_g, ns, ng_l, ng_g
  integer :: nkbl, nkl, nkr, ngg, npw_g, npwx_g
  integer :: local_pw, ipsour, igwx, ngkdist_g, ngkdist_l
  real (DP) :: occ, alat2, recvol, dr1, t1 ( 3 ), t2 ( 3 )
  real (DP) :: r1 ( 3, 3 ), r2 ( 3, 3 ), adot ( 3, 3 )
  real (DP) :: bdot ( 3, 3 ), translation ( 3, 48 )
  integer, allocatable :: kmap ( : )
  integer, allocatable :: smap ( : )
  integer, allocatable :: ifmin ( : )
  integer, allocatable :: ifmax ( : )
  integer, allocatable :: itmp ( : )
  integer, allocatable :: ngk_g ( : )
  integer, allocatable :: ipmask ( : )
  integer, allocatable :: igwk ( : )
  integer, allocatable :: igwf_l2g ( : )
  integer, allocatable :: g_g ( :, : )
  integer, allocatable :: igk_l2g ( :, : )
  real (DP), allocatable :: et_g ( :, : )
  real (DP), allocatable :: wg_g ( :, : )
  real (DP), allocatable :: energy ( :, : )
  complex (DP), allocatable :: wfng ( : )
  complex (DP), allocatable :: wfng_buf ( :, : )
  complex (DP), allocatable :: wfng_dist ( :, :, : )

  INTEGER, EXTERNAL :: atomic_number

  CALL check_inversion ( real_or_complex, nsym, s, nspin, .true., .true. )

  IF ( real_or_complex .EQ. 1 .OR. nspin .GT. 1 ) THEN
    proc_wf = .TRUE.
  ELSE
    proc_wf = .FALSE.
  ENDIF

  bad_kgrid = .FALSE.
  IF ( wfng_kgrid ) THEN
    IF ( wfng_nk1 .LE. 0 .OR. wfng_nk2 .LE. 0 .OR. wfng_nk3 .LE. 0 ) &
      bad_kgrid = .TRUE.
  ELSE
    IF ( nk1 .LE. 0 .OR. nk2 .LE. 0 .OR. nk3 .LE. 0 ) &
      bad_kgrid = .TRUE.
  ENDIF
  IF ( bad_kgrid .AND. ionode ) THEN
    WRITE ( 6, 101 )
  ENDIF

  CALL date_and_tim ( cdate, ctime )
  WRITE ( sdate, '(A2,"-",A3,"-",A4,21X)' ) cdate(1:2), cdate(3:5), cdate(6:9)
  WRITE ( stime, '(A8,24X)' ) ctime(1:8)
  IF ( real_or_complex .EQ. 1 ) THEN
    WRITE ( stitle, '("WFN-Real",24X)' )
  ELSE
    WRITE ( stitle, '("WFN-Complex",21X)' )
  ENDIF

  u = 4
  nrecord = 1
  nd = 3

  nb = nbnd
  nk_l = nks
  nk_g = nkstot
  ns = nspin
  ng_l = ngm
  ng_g = ngm_g

  nkbl = nkstot / kunit
  nkl = kunit * ( nkbl / npool )
  nkr = ( nkstot - nkl * npool ) / kunit
  IF ( my_pool_id .LT. nkr ) nkl = nkl + kunit
  iks = nkl * my_pool_id + 1
  IF ( my_pool_id .GE. nkr ) iks = iks + nkr * kunit
  ike = iks + nkl - 1

  ALLOCATE ( kmap ( nk_g ) )
  ALLOCATE ( smap ( nk_g ) )

  DO i = 1, nk_g
    j = ( i - 1 ) / ns
    k = i - 1 - j * ns
    kmap ( i ) = j + k * ( nk_g / ns ) + 1
    smap ( i ) = k + 1
  ENDDO
  ierr = 0
  DO i = 1, nk_g
    ik = kmap ( i )
    is = smap ( i )
    IF ( ik .GE. iks .AND. ik .LE. ike .AND. is .NE. isk ( ik ) ) &
      ierr = ierr + 1
  ENDDO
  CALL mp_max ( ierr )
  IF ( ierr .GT. 0 ) &
    CALL errore ( 'write_wfng', 'smap', ierr )

  alat2 = alat ** 2
  recvol = 8.0D0 * pi**3 / omega

  DO i = 1, nd
    DO j = 1, nd
      adot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        adot ( j, i ) = adot ( j, i ) + &
          at ( k, j ) * at ( k, i ) * alat2
      ENDDO
    ENDDO
  ENDDO

  DO i = 1, nd
    DO j = 1, nd
      bdot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        bdot ( j, i ) = bdot ( j, i ) + &
          bg ( k, j ) * bg ( k, i ) * tpiba2
      ENDDO
    ENDDO
  ENDDO

  ierr = 0
  IF ( ibrav .EQ. 0 ) THEN
    IF ( TRIM ( symm_type ) .EQ. 'cubic' ) THEN
      cell_symmetry = 0
    ELSEIF ( TRIM ( symm_type ) .EQ. 'hexagonal' ) THEN
      cell_symmetry = 1
    ELSE
      ierr = 1
    ENDIF
  ELSEIF ( abs ( ibrav ) .GE. 1 .AND. abs ( ibrav ) .LE. 3 ) THEN
    cell_symmetry = 0
  ELSEIF ( abs ( ibrav ) .GE. 4 .AND. abs ( ibrav ) .LE. 5 ) THEN
    cell_symmetry = 1
  ELSEIF ( abs ( ibrav ) .GE. 6 .AND. abs ( ibrav ) .LE. 14 ) THEN
    cell_symmetry = 0
  ELSE
    ierr = 1
  ENDIF
  IF ( ierr .GT. 0 ) &
    CALL errore ( 'write_wfng', 'cell_symmetry', ierr )

  ntran = nsym
  DO i = 1, ntran
    DO j = 1, nd
      DO k = 1, nd
        r1 ( k, j ) = dble ( s ( k, j, i ) )
      ENDDO
    ENDDO
    CALL invmat ( 3, r1, r2, dr1 )
    t1 ( 1 ) = dble ( ftau ( 1, i ) ) / dble ( dfftp%nr1 )
    t1 ( 2 ) = dble ( ftau ( 2, i ) ) / dble ( dfftp%nr2 )
    t1 ( 3 ) = dble ( ftau ( 3, i ) ) / dble ( dfftp%nr3 )
    DO j = 1, nd
      t2 ( j ) = 0.0D0
      DO k = 1, nd
        t2 ( j ) = t2 ( j ) + r2 ( k, j ) * t1 ( k )
      ENDDO
      IF ( t2 ( j ) .GE. eps6 + 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) + 0.5D0 ) )
      IF ( t2 ( j ) .LT. eps6 - 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) - 0.5D0 ) )
    ENDDO
    DO j = 1, nd
      translation ( j, i ) = t2 ( j ) * tpi
    ENDDO
  ENDDO

  ALLOCATE ( et_g ( nb, nk_g ) )

  DO ik = 1, nk_l
    DO ib = 1, nb
      et_g ( ib, ik ) = et ( ib, ik )
    ENDDO
  ENDDO
#ifdef __PARA
  CALL poolrecover ( et_g, nb, nk_g, nk_l )
  CALL mp_bcast ( et_g, ionode_id )
#endif

  ALLOCATE ( wg_g ( nb, nk_g ) )
  ALLOCATE ( ifmin ( nk_g ) )
  ALLOCATE ( ifmax ( nk_g ) )

  DO ik = 1, nk_l
    DO ib = 1, nb
      wg_g ( ib, ik ) = wg ( ib, ik ) * dble ( ns ) / 2.0D0
    ENDDO
  ENDDO
#ifdef __PARA
  CALL poolrecover ( wg_g, nb, nk_g, nk_l )
#endif
  DO ik = 1, nk_g
    ifmin ( ik ) = 0
  ENDDO
  DO ik = 1, nk_g
    ifmax ( ik ) = 0
  ENDDO
  DO ik = 1, nk_g
    DO ib = 1, nb
      IF ( abs ( wk ( ik ) * dble ( ns ) / 2.0D0 ) .LT. eps6 ) THEN
        occ = wg_g ( ib, ik )
      ELSE
        occ = wg_g ( ib, ik ) / ( wk ( ik ) * dble ( ns ) / 2.0D0 )
      ENDIF
      IF ( occ .GT. 0.5D0 ) THEN
        IF ( ifmin ( ik ) .EQ. 0 ) ifmin ( ik ) = ib
        ifmax ( ik ) = ib
      ENDIF
    ENDDO
  ENDDO

  IF ( wfng_occupation ) THEN
    DO ik = 1, nk_l
      DO ib = 1, nb
        IF ( ib .GE. wfng_nvmin .AND. ib .LE. wfng_nvmax ) THEN
          wg_g ( ib, ik ) = dble ( ns ) / 2.0D0
        ELSE
          wg_g ( ib, ik ) = 0.0D0
        ENDIF
      ENDDO
    ENDDO
    DO ik = 1, nk_g
      ifmin ( ik ) = wfng_nvmin
    ENDDO
    DO ik = 1, nk_g
      ifmax ( ik ) = wfng_nvmax
    ENDDO
  ENDIF

  ALLOCATE ( g_g ( nd, ng_g ) )

  DO ig = 1, ng_g
    DO id = 1, nd
      g_g ( id, ig ) = 0
    ENDDO
  ENDDO
  DO ig = 1, ng_l
    g_g ( 1, ig_l2g ( ig ) ) = mill ( 1, ig )
    g_g ( 2, ig_l2g ( ig ) ) = mill ( 2, ig )
    g_g ( 3, ig_l2g ( ig ) ) = mill ( 3, ig )
  ENDDO
  CALL mp_sum ( g_g, intra_pool_comm )

  ALLOCATE ( igk_l2g ( npwx, nk_l ) )

  ALLOCATE ( itmp ( npwx ) )
  DO ik = 1, nk_l
    DO i = 1, npwx
      itmp ( i ) = 0
    ENDDO
    npw = npwx
    CALL gk_sort ( xk ( 1, ik + iks - 1 ), ng_l, g, ecutwfc / tpiba2, &
      npw, itmp ( 1 ), g2kin )
    DO ig = 1, npw
      igk_l2g ( ig, ik ) = ig_l2g ( itmp ( ig ) )
    ENDDO
    DO ig = npw + 1, npwx
      igk_l2g ( ig, ik ) = 0
    ENDDO
    ngk ( ik ) = npw
  ENDDO
  DEALLOCATE ( itmp )

  ALLOCATE ( ngk_g ( nk_g ) )

  DO ik = 1, nk_g
    ngk_g ( ik ) = 0
  ENDDO
  DO ik = 1, nk_l
    ngk_g ( ik + iks - 1 ) = ngk ( ik )
  ENDDO
  CALL mp_sum ( ngk_g )

  npw_g = MAXVAL ( igk_l2g ( :, : ) )
  CALL mp_max ( npw_g )

  npwx_g = MAXVAL ( ngk_g ( : ) )

  CALL cryst_to_cart ( nk_g / ns, xk, at, - 1 )

  IF ( ionode ) THEN
    OPEN ( unit = u, file = TRIM ( output_file_name ), &
      form = 'unformatted', status = 'replace' )
    WRITE ( u ) stitle, sdate, stime
    WRITE ( u ) ns, ng_g, ntran, cell_symmetry, nat, ecutrho, &
      nk_g / ns, nb, npwx_g, ecutwfc
    IF ( wfng_kgrid ) THEN
      WRITE ( u ) dfftp%nr1, dfftp%nr2, dfftp%nr3, wfng_nk1, wfng_nk2, wfng_nk3, &
        wfng_dk1, wfng_dk2, wfng_dk3
    ELSE
      WRITE ( u ) dfftp%nr1, dfftp%nr2, dfftp%nr3, nk1, nk2, nk3, &
        0.5D0 * dble ( k1 ), 0.5D0 * dble ( k2 ), 0.5D0 * dble ( k3 )
    ENDIF
    WRITE ( u ) omega, alat, ( ( at ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( adot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) recvol, tpiba, ( ( bg ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( bdot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) ( ( ( s ( k, j, i ), k = 1, nd ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( translation ( j, i ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( tau ( j, i ), j = 1, nd ), atomic_number ( atm ( ityp ( i ) ) ), i = 1, nat )
    WRITE ( u ) ( ngk_g ( ik ), ik = 1, nk_g / ns )
    WRITE ( u ) ( wk ( ik ) * dble ( ns ) / 2.0D0, ik = 1, nk_g / ns )
    WRITE ( u ) ( ( xk ( id, ik ), id = 1, nd ), ik = 1, nk_g / ns )
    WRITE ( u ) ( ifmin ( ik ), ik = 1, nk_g )
    WRITE ( u ) ( ifmax ( ik ), ik = 1, nk_g )
    WRITE ( u ) ( ( et_g ( ib, ik ), ib = 1, nb ), ik = 1, nk_g )
    WRITE ( u ) ( ( wg_g ( ib, ik ), ib = 1, nb ), ik = 1, nk_g )
    WRITE ( u ) nrecord
    WRITE ( u ) ng_g
    WRITE ( u ) ( ( g_g ( id, ig ), id = 1, nd ), ig = 1, ng_g )
  ENDIF

  CALL cryst_to_cart ( nk_g / ns, xk, bg, 1 )

  DEALLOCATE ( wg_g )
  DEALLOCATE ( ifmax )
  DEALLOCATE ( ifmin )

  ALLOCATE ( igwk ( npwx_g ) )

  IF ( proc_wf ) THEN
    IF ( MOD ( npwx_g, nproc ) .EQ. 0 ) THEN
      ngkdist_l = npwx_g / nproc
    ELSE
      ngkdist_l = npwx_g / nproc + 1
    ENDIF
    ngkdist_g = ngkdist_l * nproc
    IF ( real_or_complex .EQ. 1 ) &
    ALLOCATE ( energy ( nb, ns ) )
    ALLOCATE ( wfng_buf ( ngkdist_g, ns ) )
    ALLOCATE ( wfng_dist ( ngkdist_l, nb, ns ) )
  ENDIF

  DO i = 1, nk_g

    ik = kmap ( i )
    is = smap ( i )

    IF ( real_or_complex .EQ. 1 ) THEN
      DO ib = 1, nb
        energy ( ib, is ) = et_g ( ib, i )
      ENDDO
    ENDIF

    DO j = 1, npwx_g
      igwk ( j ) = 0
    ENDDO
    ALLOCATE ( itmp ( npw_g ) )
    DO j = 1, npw_g
      itmp ( j ) = 0
    ENDDO
    IF ( ik .GE. iks .AND. ik .LE. ike ) THEN
      DO ig = 1, ngk ( ik - iks + 1 )
        itmp ( igk_l2g ( ig, ik - iks + 1 ) ) = igk_l2g ( ig, ik - iks + 1 )
      ENDDO
    ENDIF
    CALL mp_sum ( itmp )
    ngg = 0
    DO ig = 1, npw_g
      IF ( itmp ( ig ) .EQ. ig ) THEN
        ngg = ngg + 1
        igwk ( ngg ) = ig
      ENDIF
    ENDDO
    DEALLOCATE ( itmp )

    IF ( ionode ) THEN
      IF ( is .EQ. 1 ) THEN
        WRITE ( u ) nrecord
        WRITE ( u ) ngk_g ( ik )
        WRITE ( u ) ( ( g_g ( id, igwk ( ig ) ), id = 1, nd ), &
          ig = 1, ngk_g ( ik ) )
      ENDIF
    ENDIF

    local_pw = 0
    IF ( ik .GE. iks .AND. ik .LE. ike ) THEN
      CALL davcio ( evc, nwordwfc, iunwfc, ik - iks + 1, - 1 )
      local_pw = ngk ( ik - iks + 1 )
    ENDIF

    ALLOCATE ( igwf_l2g ( local_pw ) )

    DO ig = 1, local_pw
      igwf_l2g ( ig ) = 0
    ENDDO
    DO ig = 1, local_pw
      ngg = igk_l2g ( ig, ik - iks + 1 )
      DO j = 1, ngk_g ( ik )
        IF ( ngg .EQ. igwk ( j ) ) THEN
          igwf_l2g ( ig ) = j
          EXIT
        ENDIF
      ENDDO
    ENDDO

    ALLOCATE ( ipmask ( nproc ) )
    DO j = 1, nproc
      ipmask ( j ) = 0
    ENDDO
    ipsour = ionode_id
    IF ( npool .GT. 1 ) THEN
      IF ( ( ik .GE. iks ) .AND. ( ik .LE. ike ) ) THEN
        IF ( me_pool .EQ. root_pool ) ipmask ( mpime + 1 ) = 1
      ENDIF
      CALL mp_sum ( ipmask )
      DO j = 1, nproc
        IF ( ipmask ( j ) .EQ. 1 ) ipsour = j - 1
      ENDDO
    ENDIF
    DEALLOCATE ( ipmask )

    igwx = 0
    ierr = 0
    IF ( ik .GE. iks .AND. ik .LE. ike ) &
      igwx = MAXVAL ( igwf_l2g ( 1 : local_pw ) )
    CALL mp_max ( igwx, intra_pool_comm )
    IF ( ipsour .NE. ionode_id ) &
      CALL mp_get ( igwx, igwx, mpime, ionode_id, ipsour, 1 )
    ierr = 0
    IF ( ik .GE. iks .AND. ik .LE. ike .AND. igwx .NE. ngk_g ( ik ) ) &
      ierr = 1
    CALL mp_max ( ierr )
    IF ( ierr .GT. 0 ) &
      CALL errore ( 'write_wfng', 'igwx ngk_g', ierr )

    ALLOCATE ( wfng ( MAX ( 1, igwx ) ) )

    DO ib = 1, nb

      DO j = 1, igwx
        wfng ( j ) = ( 0.0D0, 0.0D0 )
      ENDDO
      IF ( npool .GT. 1 ) THEN
        IF ( ( ik .GE. iks ) .AND. ( ik .LE. ike ) ) THEN
          CALL mergewf ( evc ( :, ib ), wfng, local_pw, igwf_l2g, &
            me_pool, nproc_pool, root_pool, intra_pool_comm )
        ENDIF
        IF ( ipsour .NE. ionode_id ) THEN
          CALL mp_get ( wfng, wfng, mpime, ionode_id, ipsour, ib, &
            world_comm )
        ENDIF
      ELSE
        CALL mergewf ( evc ( :, ib ), wfng, local_pw, igwf_l2g, &
          mpime, nproc, ionode_id, world_comm )
      ENDIF

      IF ( proc_wf ) THEN
        DO ig = 1, igwx
          wfng_buf ( ig, is ) = wfng ( ig )
        ENDDO
        DO ig = igwx + 1, ngkdist_g
          wfng_buf ( ig, is ) = ( 0.0D0, 0.0D0 )
        ENDDO
#ifdef __PARA
        CALL mp_barrier ( )
        CALL MPI_Scatter ( wfng_buf ( :, is ), ngkdist_l, MPI_DOUBLE_COMPLEX, &
        wfng_dist ( :, ib, is ), ngkdist_l, MPI_DOUBLE_COMPLEX, &
        ionode_id, world_comm, ierr )
        IF ( ierr .GT. 0 ) &
          CALL errore ( 'write_wfng', 'mpi_scatter', ierr )
#else
        DO ig = 1, ngkdist_g
          wfng_dist ( ig, ib, is ) = wfng_buf ( ig, is )
        ENDDO
#endif
      ELSE
        IF ( ionode ) THEN
          WRITE ( u ) nrecord
          WRITE ( u ) ngk_g ( ik )
          WRITE ( u ) ( wfng ( ig ), ig = 1, igwx )
        ENDIF
      ENDIF

    ENDDO

    DEALLOCATE ( wfng )
    DEALLOCATE ( igwf_l2g )

    IF ( proc_wf .AND. is .EQ. ns ) THEN
      IF ( real_or_complex .EQ. 1 ) THEN
        CALL start_clock ( 'real_wfng' )
        CALL real_wfng ( ik, ngkdist_l, nb, ns, energy, wfng_dist )
        CALL stop_clock ( 'real_wfng' )
      ENDIF
      DO ib = 1, nb
        DO is = 1, ns
#ifdef __PARA
          CALL mp_barrier ( )
          CALL MPI_Gather ( wfng_dist ( :, ib, is ), ngkdist_l, &
          MPI_DOUBLE_COMPLEX, wfng_buf ( :, is ), ngkdist_l, &
          MPI_DOUBLE_COMPLEX, ionode_id, world_comm, ierr )
          IF ( ierr .GT. 0 ) &
            CALL errore ( 'write_wfng', 'mpi_gather', ierr )
#else
          DO ig = 1, ngkdist_g
            wfng_buf ( ig, is ) = wfng_dist ( ig, ib, is )
          ENDDO
#endif
        ENDDO
        IF ( ionode ) THEN
          WRITE ( u ) nrecord
          WRITE ( u ) ngk_g ( ik )
          IF ( real_or_complex .EQ. 1 ) THEN
            WRITE ( u ) ( ( dble ( wfng_buf ( ig, is ) ), &
              ig = 1, igwx ), is = 1, ns )
          ELSE
            WRITE ( u ) ( ( wfng_buf ( ig, is ), &
              ig = 1, igwx ), is = 1, ns )
          ENDIF
        ENDIF
      ENDDO
    ENDIF

  ENDDO

  DEALLOCATE ( igwk )
  DEALLOCATE ( ngk_g )
  DEALLOCATE ( igk_l2g )
  DEALLOCATE ( et_g )

  IF ( proc_wf ) THEN
    IF ( real_or_complex .EQ. 1 ) &
    DEALLOCATE ( energy )
    DEALLOCATE ( wfng_buf )
    DEALLOCATE ( wfng_dist )
  ENDIF

  IF ( ionode ) THEN
    CLOSE ( unit = u, status = 'keep' )
  ENDIF

  DEALLOCATE ( g_g )
  DEALLOCATE ( smap )
  DEALLOCATE ( kmap )

  CALL mp_barrier ( )

  RETURN

101 FORMAT ( /, 5X, "WARNING: kgrid is set to zero in the wavefunction file.", &
             /, 14X, "The resulting file will only be usable as the fine grid in inteqp.", / )

END SUBROUTINE write_wfng

!-------------------------------------------------------------------------------

SUBROUTINE real_wfng ( ik, ngkdist_l, nb, ns, energy, wfng_dist )

  USE kinds, ONLY : DP
  USE io_global, ONLY : ionode
  USE mp, ONLY : mp_sum

  IMPLICIT NONE

  integer, intent (in) :: ik, ngkdist_l, nb, ns
  real (DP), intent (in) :: energy ( nb, ns )
  complex (DP), intent (inout) :: wfng_dist ( ngkdist_l, nb, ns )

  real (DP), PARAMETER :: eps2 = 1.0D-2
  real (DP), PARAMETER :: eps5 = 1.0D-5
  real (DP), PARAMETER :: eps6 = 1.0D-6

  character :: tmpstr*80
  integer :: i, j, k, is, ib, jb, ig, inum, deg, mdeg, inc
  integer :: dimension_span, reduced_span, ierr
  real (DP) :: x
  integer, allocatable :: imap ( :, : )
  integer, allocatable :: inums ( : )
  integer, allocatable :: inull ( : )
  integer, allocatable :: null_map ( :, : )
  real (DP), allocatable :: psi ( :, : )
  real (DP), allocatable :: phi ( :, : )
  real (DP), allocatable :: vec ( : )
  complex (DP), allocatable :: wfc ( : )

  mdeg = 1
  DO is = 1, ns
    DO ib = 1, nb - 1
      deg = 1
      DO jb = ib + 1, nb
        IF ( abs ( energy ( ib, is ) - energy ( jb, is ) ) &
          .LT. eps5 * dble ( jb - ib + 1 ) ) deg = deg + 1
      ENDDO
      IF ( deg .GT. mdeg ) mdeg = deg
    ENDDO
  ENDDO
  mdeg = mdeg * 2

  ALLOCATE ( imap ( nb, ns ) )
  ALLOCATE ( inums ( ns ) )
  ALLOCATE ( inull ( nb ) )
  ALLOCATE ( null_map ( mdeg, nb ) )

  DO is = 1, ns
    inum = 1
    DO ib = 1, nb
      IF ( ib .EQ. nb ) THEN
        imap ( inum, is ) = ib
        inum = inum + 1
      ELSEIF ( abs ( energy ( ib, is ) - &
        energy ( ib + 1, is ) ) .GT. eps5 ) THEN
        imap ( inum, is ) = ib
        inum = inum + 1
      ENDIF
    ENDDO
    inum = inum - 1
    inums ( is ) = inum
  ENDDO

  ALLOCATE ( wfc ( ngkdist_l ) )
  ALLOCATE ( psi ( ngkdist_l, mdeg ) )
  ALLOCATE ( phi ( ngkdist_l, mdeg ) )
  ALLOCATE ( vec ( ngkdist_l ) )

  DO is = 1, ns
    inc = 1
    inum = inums ( is )
    DO i = 1, inum
      inull ( i ) = 1
      DO ib = inc, imap ( i, is )
        DO ig = 1, ngkdist_l
          wfc ( ig ) = wfng_dist ( ig, ib, is )
        ENDDO
        x = 0.0D0
        DO ig = 1, ngkdist_l
          x = x + dble ( wfc ( ig ) ) **2
        ENDDO
        CALL mp_sum ( x )
        IF ( x .LT. eps2 ) null_map ( inull ( i ), i ) = 0
        IF ( x .GT. eps2 ) null_map ( inull ( i ), i ) = 1
        inull ( i ) = inull ( i ) + 1
        x = 0.0D0
        DO ig = 1, ngkdist_l
          x = x + aimag ( wfc ( ig ) ) **2
        ENDDO
        CALL mp_sum ( x )
        IF ( x .LT. eps2 ) null_map ( inull ( i ), i ) = 0
        IF ( x .GT. eps2 ) null_map ( inull ( i ), i ) = 1
        inull ( i ) = inull ( i ) + 1
      ENDDO
      inull ( i ) = inull ( i ) - 1
      inc = imap ( i, is ) + 1
    ENDDO
    inc = 1
    ib = 1
    DO i = 1, inum
      k = 1
      DO j = 1, 2 * ( imap ( i, is ) - inc ) + 1, 2
        IF ( null_map ( j, i ) .EQ. 1 .OR. &
          null_map ( j + 1, i ) .EQ. 1 ) THEN
          DO ig = 1, ngkdist_l
            wfc ( ig ) = wfng_dist ( ig, ib, is )
          ENDDO
          IF ( null_map ( j, i ) .EQ. 1 ) THEN
            DO ig = 1, ngkdist_l
              phi ( ig, k ) = dble ( wfc ( ig ) )
            ENDDO
            k = k + 1
          ENDIF
          IF ( null_map ( j + 1, i ) .EQ. 1 ) THEN
            DO ig = 1, ngkdist_l
              phi ( ig, k ) = aimag ( wfc ( ig ) )
            ENDDO
            k = k + 1
          ENDIF
          ib = ib + 1
        ENDIF
      ENDDO
      dimension_span = k - 1
      IF ( dimension_span .EQ. 0 ) THEN
        ierr = 201
        WRITE ( tmpstr, 201 ) ik, is, inc
        CALL errore ( 'real_wfng', tmpstr, ierr )
      ENDIF
      DO j = 1, dimension_span
        x = 0.0D0
        DO ig = 1, ngkdist_l
          x = x + phi ( ig, j ) **2
        ENDDO
        CALL mp_sum ( x )
        x = sqrt ( x )
        DO ig = 1, ngkdist_l
          phi ( ig, j ) = phi ( ig, j ) / x
        ENDDO
      ENDDO
!
! the Gram-Schmidt process begins
!
      reduced_span = 1
      DO ig = 1, ngkdist_l
        psi ( ig, 1 ) = phi ( ig, 1 )
      ENDDO
      DO j = 1, dimension_span - 1
        DO ig = 1, ngkdist_l
          vec ( ig ) = phi ( ig, j + 1 )
        ENDDO
        DO k = 1, reduced_span
          x = 0.0D0
          DO ig = 1, ngkdist_l
            x = x + phi ( ig, j + 1 ) * psi ( ig, k )
          ENDDO
          CALL mp_sum ( x )
          DO ig = 1, ngkdist_l
            vec ( ig ) = vec ( ig ) - psi ( ig, k ) * x
          ENDDO
        ENDDO
        x = 0.0D0
        DO ig = 1, ngkdist_l
          x = x + vec ( ig ) **2
        ENDDO
        CALL mp_sum ( x )
        x = sqrt ( x )
        IF ( x .GT. eps6 ) THEN
          reduced_span = reduced_span + 1
          DO ig = 1, ngkdist_l
            psi ( ig, reduced_span ) = vec ( ig ) / x
          ENDDO
        ENDIF
      ENDDO
!
! the Gram-Schmidt process ends
!
      IF ( reduced_span .LT. imap ( i, is ) - inc + 1 ) THEN
        ierr = 202
        WRITE ( tmpstr, 202 ) ik, is, inc
        CALL errore ( 'real_wfng', tmpstr, ierr )
      ENDIF
      DO ib = inc, imap ( i, is )
        DO ig = 1, ngkdist_l
          wfng_dist ( ig, ib, is ) = &
          CMPLX ( psi ( ig, ib - inc + 1 ), 0.0D0 )
        ENDDO
      ENDDO
      inc = imap ( i, is ) + 1
    ENDDO
  ENDDO

  DEALLOCATE ( vec )
  DEALLOCATE ( phi )
  DEALLOCATE ( psi )
  DEALLOCATE ( wfc )
  DEALLOCATE ( null_map )
  DEALLOCATE ( inull )
  DEALLOCATE ( inums )
  DEALLOCATE ( imap )

  RETURN

201 FORMAT("failed Gram-Schmidt dimension span for kpoint =",i6," spin =",i2," band =",i6)
202 FORMAT("failed Gram-Schmidt reduced span for kpoint =",i6," spin =",i2," band =",i6)

END SUBROUTINE real_wfng

!-------------------------------------------------------------------------------

SUBROUTINE write_rhog ( output_file_name, real_or_complex, symm_type )

  USE cell_base, ONLY : omega, alat, tpiba, tpiba2, at, bg, ibrav
  USE constants, ONLY : pi, tpi, eps6
  USE fft_base, ONLY : dfftp
  USE gvect, ONLY : ngm, ngm_g, ig_l2g, mill, ecutrho
  USE io_global, ONLY : ionode
  USE ions_base, ONLY : nat, atm, ityp, tau 
  USE kinds, ONLY : DP
  USE lsda_mod, ONLY : nspin
  USE mp, ONLY : mp_sum
  USE mp_global, ONLY : intra_pool_comm
  USE scf, ONLY : rho
  USE symm_base, ONLY : s, ftau, nsym

  IMPLICIT NONE

  character ( len = 256 ), intent (in) :: output_file_name
  integer, intent (in) :: real_or_complex
  character ( len = 9 ), intent (in) :: symm_type

  character :: cdate*9, ctime*9, sdate*32, stime*32, stitle*32
  integer :: u, id, is, ig, i, j, k, ierr
  integer :: nd, ns, ng_l, ng_g
  integer :: ntran, cell_symmetry, nrecord
  real (DP) :: alat2, recvol, dr1, t1 ( 3 ), t2 ( 3 )
  real (DP) :: r1 ( 3, 3 ), r2 ( 3, 3 ), adot ( 3, 3 )
  real (DP) :: bdot ( 3, 3 ), translation ( 3, 48 )
  integer, allocatable :: g_g ( :, : )
  complex (DP), allocatable :: rhog_g ( :, : )

  INTEGER, EXTERNAL :: atomic_number

  CALL check_inversion ( real_or_complex, nsym, s, nspin, .true., .true. )

  CALL date_and_tim ( cdate, ctime )
  WRITE ( sdate, '(A2,"-",A3,"-",A4,21X)' ) cdate(1:2), cdate(3:5), cdate(6:9)
  WRITE ( stime, '(A8,24X)' ) ctime(1:8)
  IF ( real_or_complex .EQ. 1 ) THEN
    WRITE ( stitle, '("RHO-Real",24X)' )
  ELSE
    WRITE ( stitle, '("RHO-Complex",21X)' )
  ENDIF

  u = 4
  nrecord = 1
  nd = 3

  ns = nspin
  ng_l = ngm
  ng_g = ngm_g

  ierr = 0
  IF ( ibrav .EQ. 0 ) THEN
    IF ( TRIM ( symm_type ) .EQ. 'cubic' ) THEN
      cell_symmetry = 0
    ELSEIF ( TRIM ( symm_type ) .EQ. 'hexagonal' ) THEN
      cell_symmetry = 1
    ELSE
      ierr = 1
    ENDIF
  ELSEIF ( abs ( ibrav ) .GE. 1 .AND. abs ( ibrav ) .LE. 3 ) THEN
    cell_symmetry = 0
  ELSEIF ( abs ( ibrav ) .GE. 4 .AND. abs ( ibrav ) .LE. 5 ) THEN
    cell_symmetry = 1
  ELSEIF ( abs ( ibrav ) .GE. 6 .AND. abs ( ibrav ) .LE. 14 ) THEN
    cell_symmetry = 0
  ELSE
    ierr = 1
  ENDIF
  IF ( ierr .GT. 0 ) &
    CALL errore ( 'write_rhog', 'cell_symmetry', ierr )

  ntran = nsym
  DO i = 1, ntran
    DO j = 1, nd
      DO k = 1, nd
        r1 ( k, j ) = dble ( s ( k, j, i ) )
      ENDDO
    ENDDO
    CALL invmat ( 3, r1, r2, dr1 )
    t1 ( 1 ) = dble ( ftau ( 1, i ) ) / dble ( dfftp%nr1 )
    t1 ( 2 ) = dble ( ftau ( 2, i ) ) / dble ( dfftp%nr2 )
    t1 ( 3 ) = dble ( ftau ( 3, i ) ) / dble ( dfftp%nr3 )
    DO j = 1, nd
      t2 ( j ) = 0.0D0
      DO k = 1, nd
        t2 ( j ) = t2 ( j ) + r2 ( k, j ) * t1 ( k )
      ENDDO
      IF ( t2 ( j ) .GE. eps6 + 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) + 0.5D0 ) )
      IF ( t2 ( j ) .LT. eps6 - 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) - 0.5D0 ) )
    ENDDO
    DO j = 1, nd
      translation ( j, i ) = t2 ( j ) * tpi
    ENDDO
  ENDDO

  alat2 = alat ** 2
  recvol = 8.0D0 * pi**3 / omega

  DO i = 1, nd
    DO j = 1, nd
      adot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        adot ( j, i ) = adot ( j, i ) + &
          at ( k, j ) * at ( k, i ) * alat2
      ENDDO
    ENDDO
  ENDDO

  DO i = 1, nd
    DO j = 1, nd
      bdot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        bdot ( j, i ) = bdot ( j, i ) + &
          bg ( k, j ) * bg ( k, i ) * tpiba2
      ENDDO
    ENDDO
  ENDDO

  ALLOCATE ( g_g ( nd, ng_g ) )
  ALLOCATE ( rhog_g ( ng_g, ns ) )

  DO ig = 1, ng_g
    DO id = 1, nd
      g_g ( id, ig ) = 0
    ENDDO
  ENDDO
  DO is = 1, ns
    DO ig = 1, ng_g
      rhog_g ( ig, is ) = ( 0.0D0, 0.0D0 )
    ENDDO
  ENDDO

  DO ig = 1, ng_l
    g_g ( 1, ig_l2g ( ig ) ) = mill ( 1, ig )
    g_g ( 2, ig_l2g ( ig ) ) = mill ( 2, ig )
    g_g ( 3, ig_l2g ( ig ) ) = mill ( 3, ig )
  ENDDO
  DO is = 1, ns
    DO ig = 1, ng_l
      rhog_g ( ig_l2g ( ig ), is ) = rho%of_g ( ig, is )
    ENDDO
  ENDDO

  CALL mp_sum ( g_g, intra_pool_comm )
  CALL mp_sum ( rhog_g, intra_pool_comm )

  DO is = 1, ns
    DO ig = 1, ng_g
      rhog_g ( ig, is ) = rhog_g ( ig, is ) * CMPLX ( omega, 0.0D0 )
    ENDDO
  ENDDO

  IF ( ionode ) THEN
    OPEN ( unit = u, file = TRIM ( output_file_name ), &
      form = 'unformatted', status = 'replace' )
    WRITE ( u ) stitle, sdate, stime
    WRITE ( u ) ns, ng_g, ntran, cell_symmetry, nat, ecutrho
    WRITE ( u ) dfftp%nr1, dfftp%nr2, dfftp%nr3
    WRITE ( u ) omega, alat, ( ( at ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( adot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) recvol, tpiba, ( ( bg ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( bdot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) ( ( ( s ( k, j, i ), k = 1, nd ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( translation ( j, i ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( tau ( j, i ), j = 1, nd ), atomic_number ( atm ( ityp ( i ) ) ), i = 1, nat )
    WRITE ( u ) nrecord
    WRITE ( u ) ng_g
    WRITE ( u ) ( ( g_g ( id, ig ), id = 1, nd ), ig = 1, ng_g )
    WRITE ( u ) nrecord
    WRITE ( u ) ng_g
    IF ( real_or_complex .EQ. 1 ) THEN
      WRITE ( u ) ( ( dble ( rhog_g ( ig, is ) ), &
        ig = 1, ng_g ), is = 1, ns )
    ELSE
      WRITE ( u ) ( ( rhog_g ( ig, is ), &
        ig = 1, ng_g ), is = 1, ns )
    ENDIF
    CLOSE ( unit = u, status = 'keep' )
  ENDIF

  DEALLOCATE ( rhog_g )
  DEALLOCATE ( g_g )

  RETURN

END SUBROUTINE write_rhog

!-------------------------------------------------------------------------------

SUBROUTINE write_vxcg ( output_file_name, real_or_complex, symm_type, &
  input_dft, exx_flag )

  USE cell_base, ONLY : omega, alat, tpiba, tpiba2, at, bg, ibrav
  USE constants, ONLY : pi, tpi, eps6
  USE ener, ONLY : etxc, vtxc
  USE fft_base, ONLY : dfftp
  USE fft_interfaces, ONLY : fwfft
  USE funct, ONLY : enforce_input_dft
  USE gvect, ONLY : ngm, ngm_g, ig_l2g, nl, mill, ecutrho
  USE io_global, ONLY : ionode
  USE ions_base, ONLY : nat, atm, ityp, tau 
  USE kinds, ONLY : DP
  USE lsda_mod, ONLY : nspin
  USE mp, ONLY : mp_sum
  USE mp_global, ONLY : intra_pool_comm
  USE scf, ONLY : rho, rho_core, rhog_core
  USE symm_base, ONLY : s, ftau, nsym
  USE wavefunctions_module, ONLY : psic
#ifdef EXX
  USE funct, ONLY : start_exx, stop_exx
#endif

  IMPLICIT NONE

  character ( len = 256 ), intent (in) :: output_file_name
  integer, intent (in) :: real_or_complex
  character ( len = 9 ), intent (in) :: symm_type
  character ( len = 20 ), intent (in) :: input_dft
  logical, intent (in) :: exx_flag

  character :: cdate*9, ctime*9, sdate*32, stime*32, stitle*32
  integer :: u, id, is, ir, ig, i, j, k, ierr
  integer :: nd, ns, nr, ng_l, ng_g
  integer :: ntran, cell_symmetry, nrecord
  real (DP) :: alat2, recvol, dr1, t1 ( 3 ), t2 ( 3 )
  real (DP) :: r1 ( 3, 3 ), r2 ( 3, 3 ), adot ( 3, 3 )
  real (DP) :: bdot ( 3, 3 ), translation ( 3, 48 )
  integer, allocatable :: g_g ( :, : )
  real (DP), allocatable :: vxcr_g ( :, : )
  complex (DP), allocatable :: vxcg_g ( :, : )

  INTEGER, EXTERNAL :: atomic_number

  CALL check_inversion ( real_or_complex, nsym, s, nspin, .true., .true. )

  CALL date_and_tim ( cdate, ctime )
  WRITE ( sdate, '(A2,"-",A3,"-",A4,21X)' ) cdate(1:2), cdate(3:5), cdate(6:9)
  WRITE ( stime, '(A8,24X)' ) ctime(1:8)
  IF ( real_or_complex .EQ. 1 ) THEN
    WRITE ( stitle, '("VXC-Real",24X)' )
  ELSE
    WRITE ( stitle, '("VXC-Complex",21X)' )
  ENDIF

  u = 4
  nrecord = 1
  nd = 3

  ns = nspin
  nr = dfftp%nnr
  ng_l = ngm
  ng_g = ngm_g

  ierr = 0
  IF ( ibrav .EQ. 0 ) THEN
    IF ( TRIM ( symm_type ) .EQ. 'cubic' ) THEN
      cell_symmetry = 0
    ELSEIF ( TRIM ( symm_type ) .EQ. 'hexagonal' ) THEN
      cell_symmetry = 1
    ELSE
      ierr = 1
    ENDIF
  ELSEIF ( abs ( ibrav ) .GE. 1 .AND. abs ( ibrav ) .LE. 3 ) THEN
    cell_symmetry = 0
  ELSEIF ( abs ( ibrav ) .GE. 4 .AND. abs ( ibrav ) .LE. 5 ) THEN
    cell_symmetry = 1
  ELSEIF ( abs ( ibrav ) .GE. 6 .AND. abs ( ibrav ) .LE. 14 ) THEN
    cell_symmetry = 0
  ELSE
    ierr = 1
  ENDIF
  IF ( ierr .GT. 0 ) &
    CALL errore ( 'write_vxcg', 'cell_symmetry', ierr )

  ntran = nsym
  DO i = 1, ntran
    DO j = 1, nd
      DO k = 1, nd
        r1 ( k, j ) = dble ( s ( k, j, i ) )
      ENDDO
    ENDDO
    CALL invmat ( 3, r1, r2, dr1 )
    t1 ( 1 ) = dble ( ftau ( 1, i ) ) / dble ( dfftp%nr1 )
    t1 ( 2 ) = dble ( ftau ( 2, i ) ) / dble ( dfftp%nr2 )
    t1 ( 3 ) = dble ( ftau ( 3, i ) ) / dble ( dfftp%nr3 )
    DO j = 1, nd
      t2 ( j ) = 0.0D0
      DO k = 1, nd
        t2 ( j ) = t2 ( j ) + r2 ( k, j ) * t1 ( k )
      ENDDO
      IF ( t2 ( j ) .GE. eps6 + 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) + 0.5D0 ) )
      IF ( t2 ( j ) .LT. eps6 - 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) - 0.5D0 ) )
    ENDDO
    DO j = 1, nd
      translation ( j, i ) = t2 ( j ) * tpi
    ENDDO
  ENDDO

  alat2 = alat ** 2
  recvol = 8.0D0 * pi**3 / omega

  DO i = 1, nd
    DO j = 1, nd
      adot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        adot ( j, i ) = adot ( j, i ) + &
          at ( k, j ) * at ( k, i ) * alat2
      ENDDO
    ENDDO
  ENDDO

  DO i = 1, nd
    DO j = 1, nd
      bdot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        bdot ( j, i ) = bdot ( j, i ) + &
          bg ( k, j ) * bg ( k, i ) * tpiba2
      ENDDO
    ENDDO
  ENDDO

  ALLOCATE ( g_g ( nd, ng_g ) )
  ALLOCATE ( vxcr_g ( nr, ns ) )
  ALLOCATE ( vxcg_g ( ng_g, ns ) )

  DO ig = 1, ng_g
    DO id = 1, nd
      g_g ( id, ig ) = 0
    ENDDO
  ENDDO
  DO is = 1, ns
    DO ig = 1, ng_g
      vxcg_g ( ig, is ) = ( 0.0D0, 0.0D0 )
    ENDDO
  ENDDO

! In GW calculations, the exchange-correlation
! potential should not include partial core correction.
! Assign rho_core and rhog_core to zero.

  rho_core ( : ) = 0.0D0
  rhog_core ( : ) = ( 0.0D0, 0.0D0 )

  DO ig = 1, ng_l
    g_g ( 1, ig_l2g ( ig ) ) = mill ( 1, ig )
    g_g ( 2, ig_l2g ( ig ) ) = mill ( 2, ig )
    g_g ( 3, ig_l2g ( ig ) ) = mill ( 3, ig )
  ENDDO
  CALL enforce_input_dft ( input_dft )
#ifdef EXX
  IF ( exx_flag ) CALL start_exx ( )
#endif
  vxcr_g ( :, : ) = 0.0D0
  CALL v_xc ( rho, rho_core, rhog_core, etxc, vtxc, vxcr_g )
#ifdef EXX
  IF ( exx_flag ) CALL stop_exx ( )
#endif
  DO is = 1, ns
    DO ir = 1, nr
      psic ( ir ) = CMPLX ( vxcr_g ( ir, is ), 0.0D0 )
    ENDDO
    CALL fwfft ( 'Dense', psic, dfftp )
    DO ig = 1, ng_l
      vxcg_g ( ig_l2g ( ig ), is ) = psic ( nl ( ig ) )
    ENDDO
  ENDDO

  CALL mp_sum ( g_g, intra_pool_comm )
  CALL mp_sum ( vxcg_g, intra_pool_comm )

  IF ( ionode ) THEN
    OPEN ( unit = u, file = TRIM ( output_file_name ), &
      form = 'unformatted', status = 'replace' )
    WRITE ( u ) stitle, sdate, stime
    WRITE ( u ) ns, ng_g, ntran, cell_symmetry, nat, ecutrho
    WRITE ( u ) dfftp%nr1, dfftp%nr2, dfftp%nr3
    WRITE ( u ) omega, alat, ( ( at ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( adot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) recvol, tpiba, ( ( bg ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( bdot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) ( ( ( s ( k, j, i ), k = 1, nd ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( translation ( j, i ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( tau ( j, i ), j = 1, nd ), atomic_number ( atm ( ityp ( i ) ) ), i = 1, nat )
    WRITE ( u ) nrecord
    WRITE ( u ) ng_g
    WRITE ( u ) ( ( g_g ( id, ig ), id = 1, nd ), ig = 1, ng_g )
    WRITE ( u ) nrecord
    WRITE ( u ) ng_g
    IF ( real_or_complex .EQ. 1 ) THEN
      WRITE ( u ) ( ( dble ( vxcg_g ( ig, is ) ), &
        ig = 1, ng_g ), is = 1, ns )
    ELSE
      WRITE ( u ) ( ( vxcg_g ( ig, is ), &
        ig = 1, ng_g ), is = 1, ns )
    ENDIF
    CLOSE ( unit = u, status = 'keep' )
  ENDIF

  DEALLOCATE ( vxcg_g )
  DEALLOCATE ( vxcr_g )
  DEALLOCATE ( g_g )

  RETURN

END SUBROUTINE write_vxcg

!-------------------------------------------------------------------------------

SUBROUTINE write_vxc0 ( output_file_name, input_dft, exx_flag )

  USE constants, ONLY : RYTOEV
  USE ener, ONLY : etxc, vtxc
  USE fft_base, ONLY : dfftp
  USE fft_interfaces, ONLY : fwfft
  USE funct, ONLY : enforce_input_dft
  USE gvect, ONLY : ngm, nl, mill
  USE io_global, ONLY : ionode
  USE kinds, ONLY : DP
  USE lsda_mod, ONLY : nspin
  USE mp, ONLY : mp_sum
  USE mp_global, ONLY : intra_pool_comm
  USE scf, ONLY : rho, rho_core, rhog_core
  USE wavefunctions_module, ONLY : psic
#ifdef EXX
  USE funct, ONLY : start_exx, stop_exx
#endif

  IMPLICIT NONE

  character ( len = 256 ), intent (in) :: output_file_name
  character ( len = 20 ), intent (in) :: input_dft
  logical, intent (in) :: exx_flag

  integer :: u
  integer :: is, ir, ig
  integer :: nd, ns, nr, ng_l
  real (DP), allocatable :: vxcr_g ( :, : )
  complex (DP), allocatable :: vxc0_g ( : )

  u = 4
  nd = 3

  ns = nspin
  nr = dfftp%nnr
  ng_l = ngm

  ALLOCATE ( vxcr_g ( nr, ns ) )
  ALLOCATE ( vxc0_g ( ns ) )

  DO is = 1, ns
    vxc0_g ( is ) = ( 0.0D0, 0.0D0 )
  ENDDO

! In GW calculations, the exchange-correlation
! potential should not include partial core correction.
! Assign rho_core and rhog_core to zero.

  rho_core ( : ) = 0.0D0
  rhog_core ( : ) = ( 0.0D0, 0.0D0 )

  CALL enforce_input_dft ( input_dft )
#ifdef EXX
  IF ( exx_flag ) CALL start_exx ( )
#endif
  vxcr_g ( :, : ) = 0.0D0
  CALL v_xc ( rho, rho_core, rhog_core, etxc, vtxc, vxcr_g )
#ifdef EXX
  IF ( exx_flag ) CALL stop_exx ( )
#endif
  DO is = 1, ns
    DO ir = 1, nr
      psic ( ir ) = CMPLX ( vxcr_g ( ir, is ), 0.0D0 )
    ENDDO
    CALL fwfft ( 'Dense', psic, dfftp )
    DO ig = 1, ng_l
      IF ( mill ( 1, ig ) .EQ. 0 .AND. mill ( 2, ig ) .EQ. 0 .AND. &
        mill ( 3, ig ) .EQ. 0 ) vxc0_g ( is ) = psic ( nl ( ig ) )
    ENDDO
  ENDDO

  CALL mp_sum ( vxc0_g, intra_pool_comm )

  DO is = 1, ns
    vxc0_g ( is ) = vxc0_g ( is ) * CMPLX ( RYTOEV, 0.0D0 )
  ENDDO

  IF ( ionode ) THEN
    OPEN (unit = u, file = TRIM (output_file_name), &
      form = 'formatted', status = 'replace')
    WRITE ( u, 101 )
    DO is = 1, ns
      WRITE ( u, 102 ) is, vxc0_g ( is )
    ENDDO
    WRITE ( u, 103 )
    CLOSE (unit = u, status = 'keep')
  ENDIF

  DEALLOCATE ( vxcr_g )
  DEALLOCATE ( vxc0_g )

  RETURN

101 FORMAT ( /, 5X, "--------------------------------------------", &
             /, 5X, "spin    Re Vxc(G=0) [eV]    Im Vxc(G=0) [eV]", &
             /, 5X, "--------------------------------------------" )
102 FORMAT ( 5X, I1, 3X, 2F20.15 )
103 FORMAT ( 5X, "--------------------------------------------", / )

END SUBROUTINE write_vxc0

!-------------------------------------------------------------------------------

SUBROUTINE write_vxc_r (output_file_name, diag_nmin, diag_nmax, &
  offdiag_nmin, offdiag_nmax, input_dft, exx_flag)

  USE kinds, ONLY : DP
  USE constants, ONLY : rytoev
  USE cell_base, ONLY : tpiba2, at, bg
  USE ener, ONLY : etxc, vtxc
  USE fft_base, ONLY : dfftp
  USE fft_interfaces, ONLY : invfft
  USE funct, ONLY : enforce_input_dft
  USE gvect, ONLY : ngm, g, nl
  USE io_files, ONLY : nwordwfc, iunwfc
  USE io_global, ONLY : ionode
  USE klist, ONLY : xk, nkstot
  USE lsda_mod, ONLY : nspin, isk
  USE mp, ONLY : mp_sum
  USE mp_global, ONLY : kunit, my_pool_id, intra_pool_comm, &
    inter_pool_comm, npool
  USE scf, ONLY : rho, rho_core, rhog_core
  USE wavefunctions_module, ONLY : evc, psic
  USE wvfct, ONLY : npw, nbnd, igk, g2kin, ecutwfc
#ifdef EXX
  USE funct, ONLY : start_exx, stop_exx
#endif

  IMPLICIT NONE

  character (len = 256), intent (in) :: output_file_name
  integer, intent (inout) :: diag_nmin
  integer, intent (inout) :: diag_nmax
  integer, intent (inout) :: offdiag_nmin
  integer, intent (inout) :: offdiag_nmax
  character (len = 20), intent (in) :: input_dft
  logical, intent (in) :: exx_flag

  integer :: ik, is, ib, ig, ir, u, nkbl, nkl, nkr, iks, ike, &
    ndiag, noffdiag, ib2
  real (DP) :: dummyr
  complex (DP) :: dummyc
  real (DP), allocatable :: mtxeld (:, :)
  complex (DP), allocatable :: mtxelo (:, :, :)
  real (DP), allocatable :: vxcr (:, :)
  complex (DP), allocatable :: psic2 (:)

  IF (diag_nmin .LT. 1) diag_nmin = 1
  IF (diag_nmax .GT. nbnd) then
    write(0,*) 'WARNING: resetting diag_nmax to max number of bands'
    diag_nmax = nbnd
  ENDIF
  ndiag = MAX (diag_nmax - diag_nmin + 1, 0)
  IF (offdiag_nmin .LT. 1) offdiag_nmin = 1
  IF (offdiag_nmax .GT. nbnd)  then
    write(0,*) 'WARNING: resetting offdiag_nmax to max number of bands'
    offdiag_nmax = nbnd
  ENDIF
  noffdiag = MAX (offdiag_nmax - offdiag_nmin + 1, 0)
  IF (ndiag .EQ. 0 .AND. noffdiag .EQ. 0) RETURN

  u = 4

  nkbl = nkstot / kunit
  nkl = kunit * (nkbl / npool)
  nkr = (nkstot - nkl * npool) / kunit
  IF (my_pool_id .LT. nkr) nkl = nkl + kunit
  iks = nkl * my_pool_id + 1
  IF (my_pool_id .GE. nkr) iks = iks + nkr * kunit
  ike = iks + nkl - 1

  IF (ndiag .GT. 0) THEN
    ALLOCATE (mtxeld (ndiag, nkstot))
    mtxeld (:, :) = 0.0D0
  ENDIF
  IF (noffdiag .GT. 0) THEN
    ALLOCATE (mtxelo (noffdiag, noffdiag, nkstot))
    mtxelo (:, :, :) = (0.0D0, 0.0D0)
  ENDIF

  ALLOCATE (vxcr (dfftp%nnr, nspin))
  IF (noffdiag .GT. 0) ALLOCATE (psic2 (dfftp%nnr))

  CALL enforce_input_dft (input_dft)
#ifdef EXX
  IF (exx_flag) CALL start_exx ()
#endif

! In GW calculations, the exchange-correlation
! potential should not include partial core correction.
! Assign rho_core and rhog_core to zero.

  rho_core (:) = 0.0D0
  rhog_core (:) = (0.0D0, 0.0D0)

  vxcr (:, :) = 0.0D0
  CALL v_xc (rho, rho_core, rhog_core, etxc, vtxc, vxcr)

  DO ik = iks, ike
    CALL gk_sort (xk (1, ik - iks + 1), ngm, g, ecutwfc &
      / tpiba2, npw, igk, g2kin)
    CALL davcio (evc, nwordwfc, iunwfc, ik - iks + 1, -1)
    IF (ndiag .GT. 0) THEN
      DO ib = diag_nmin, diag_nmax
        psic (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          psic (nl (igk (ig))) = evc (ig, ib)
        ENDDO
        CALL invfft ('Dense', psic, dfftp)
        dummyr = 0.0D0
        DO ir = 1, dfftp%nnr
          dummyr = dummyr + vxcr (ir, isk (ik)) &
            * (dble (psic (ir)) **2 + aimag (psic (ir)) **2)
        ENDDO
        dummyr = dummyr * rytoev / dble (dfftp%nr1x * dfftp%nr2x * dfftp%nr3x)
        CALL mp_sum (dummyr, intra_pool_comm)
        mtxeld (ib - diag_nmin + 1, ik) = dummyr
      ENDDO
    ENDIF
    IF (noffdiag .GT. 0) THEN
      DO ib = offdiag_nmin, offdiag_nmax
        psic (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          psic (nl (igk (ig))) = evc (ig, ib)
        ENDDO
        CALL invfft ('Dense', psic, dfftp)
        DO ib2 = offdiag_nmin, offdiag_nmax
          psic2 (:) = (0.0D0, 0.0D0)
          DO ig = 1, npw
            psic2 (nl (igk (ig))) = evc (ig, ib2)
          ENDDO
          CALL invfft ('Dense', psic2, dfftp)
          dummyc = (0.0D0, 0.0D0)
          DO ir = 1, dfftp%nnr
            dummyc = dummyc + CMPLX (vxcr (ir, isk (ik)), 0.0D0) &
              * conjg (psic2 (ir)) * psic (ir)
          ENDDO
          dummyc = dummyc &
            * CMPLX (rytoev / dble (dfftp%nr1x * dfftp%nr2x * dfftp%nr3x), 0.0D0)
          CALL mp_sum (dummyc, intra_pool_comm)
          mtxelo (ib2 - offdiag_nmin + 1, ib - offdiag_nmin &
            + 1, ik) = dummyc
        ENDDO
      ENDDO
    ENDIF
  ENDDO

#ifdef EXX
  IF (exx_flag) CALL stop_exx ()
#endif

  DEALLOCATE (vxcr)
  IF (noffdiag .GT. 0) DEALLOCATE (psic2)

  IF (ndiag .GT. 0) CALL mp_sum (mtxeld, inter_pool_comm)
  IF (noffdiag .GT. 0) CALL mp_sum (mtxelo, inter_pool_comm)

  CALL cryst_to_cart (nkstot, xk, at, -1)

  IF (ionode) THEN
    OPEN (unit = u, file = TRIM (output_file_name), &
      form = 'formatted', status = 'replace')
    DO ik = 1, nkstot / nspin
      WRITE (u, 101) xk(:, ik), nspin * ndiag, &
        nspin * noffdiag **2
      DO is = 1, nspin
        IF (ndiag .GT. 0) THEN
          DO ib = diag_nmin, diag_nmax
            WRITE (u, 102) is, ib, mtxeld &
              (ib - diag_nmin + 1, ik + (is - 1) * nkstot / nspin), &
              0.0D0
          ENDDO
        ENDIF
        IF (noffdiag .GT. 0) THEN
          DO ib = offdiag_nmin, offdiag_nmax
            DO ib2 = offdiag_nmin, offdiag_nmax
              WRITE (u, 103) is, ib2, ib, mtxelo &
                (ib2 - offdiag_nmin + 1, ib - offdiag_nmin + 1, &
                ik + (is - 1) * nkstot / nspin)
            ENDDO
          ENDDO
        ENDIF
      ENDDO
    ENDDO
    CLOSE (unit = u, status = 'keep')
  ENDIF

  CALL cryst_to_cart (nkstot, xk, bg, 1)

  IF (ndiag .GT. 0) DEALLOCATE (mtxeld)
  IF (noffdiag .GT. 0) DEALLOCATE (mtxelo)

  RETURN

  101 FORMAT (3F13.9, 2I8)
  102 FORMAT (2I8, 2F15.9)
  103 FORMAT (3I8, 2F15.9)

END SUBROUTINE write_vxc_r

!-------------------------------------------------------------------------------

SUBROUTINE write_vxc_g (output_file_name, diag_nmin, diag_nmax, &
  offdiag_nmin, offdiag_nmax, input_dft, exx_flag)

  USE constants, ONLY : rytoev
  USE cell_base, ONLY : tpiba2, at, bg
  USE ener, ONLY : etxc, vtxc
  USE fft_base, ONLY : dfftp
  USE fft_interfaces, ONLY : fwfft, invfft
  USE funct, ONLY : enforce_input_dft
  USE gvect, ONLY : ngm, g, nl
  USE io_files, ONLY : nwordwfc, iunwfc
  USE io_global, ONLY : ionode
  USE kinds, ONLY : DP
  USE klist, ONLY : xk, nkstot
  USE lsda_mod, ONLY : nspin, isk
  USE mp, ONLY : mp_sum
  USE mp_global, ONLY : kunit, my_pool_id, intra_pool_comm, &
    inter_pool_comm, npool
  USE scf, ONLY : rho, rho_core, rhog_core
  USE wavefunctions_module, ONLY : evc, psic
  USE wvfct, ONLY : npwx, npw, nbnd, igk, g2kin, ecutwfc
#ifdef EXX
  USE funct, ONLY : start_exx, stop_exx, exx_is_active
  USE exx, ONLY : vexx
#endif

  IMPLICIT NONE

  character (len = 256), intent (in) :: output_file_name
  integer, intent (inout) :: diag_nmin
  integer, intent (inout) :: diag_nmax
  integer, intent (inout) :: offdiag_nmin
  integer, intent (inout) :: offdiag_nmax
  character (len = 20), intent (in) :: input_dft
  logical, intent (in) :: exx_flag

  integer :: ik, is, ib, ig, ir, u, nkbl, nkl, nkr, iks, ike, &
    ndiag, noffdiag, ib2
  complex (DP) :: dummy
  complex (DP), allocatable :: mtxeld (:, :)
  complex (DP), allocatable :: mtxelo (:, :, :)
  real (DP), allocatable :: vxcr (:, :)
  complex (DP), allocatable :: psic2 (:)
  complex (DP), allocatable :: hpsi (:)

  IF (diag_nmin .LT. 1) diag_nmin = 1
  IF (diag_nmax .GT. nbnd) diag_nmax = nbnd
  ndiag = MAX (diag_nmax - diag_nmin + 1, 0)
  IF (offdiag_nmin .LT. 1) offdiag_nmin = 1
  IF (offdiag_nmax .GT. nbnd) offdiag_nmax = nbnd
  noffdiag = MAX (offdiag_nmax - offdiag_nmin + 1, 0)
  IF (ndiag .EQ. 0 .AND. noffdiag .EQ. 0) RETURN

  u = 4

  nkbl = nkstot / kunit
  nkl = kunit * (nkbl / npool)
  nkr = (nkstot - nkl * npool) / kunit
  IF (my_pool_id .LT. nkr) nkl = nkl + kunit
  iks = nkl * my_pool_id + 1
  IF (my_pool_id .GE. nkr) iks = iks + nkr * kunit
  ike = iks + nkl - 1

  IF (ndiag .GT. 0) THEN
    ALLOCATE (mtxeld (ndiag, nkstot))
    mtxeld (:, :) = (0.0D0, 0.0D0)
  ENDIF
  IF (noffdiag .GT. 0) THEN
    ALLOCATE (mtxelo (noffdiag, noffdiag, nkstot))
    mtxelo (:, :, :) = (0.0D0, 0.0D0)
  ENDIF

  ALLOCATE (vxcr (dfftp%nnr, nspin))
  IF (noffdiag .GT. 0) ALLOCATE (psic2 (dfftp%nnr))
  ALLOCATE (hpsi (dfftp%nnr))

  CALL enforce_input_dft (input_dft)
#ifdef EXX
  IF (exx_flag) CALL start_exx ()
#endif

! In GW calculations, the exchange-correlation
! potential should not include partial core correction.
! Assign rho_core and rhog_core to zero.

  rho_core (:) = 0.0D0
  rhog_core (:) = (0.0D0, 0.0D0)

  vxcr (:, :) = 0.0D0
  CALL v_xc (rho, rho_core, rhog_core, etxc, vtxc, vxcr)

  DO ik = iks, ike
    CALL gk_sort (xk (1, ik - iks + 1), ngm, g, ecutwfc &
      / tpiba2, npw, igk, g2kin)
    CALL davcio (evc, nwordwfc, iunwfc, ik - iks + 1, -1)
    IF (ndiag .GT. 0) THEN
      DO ib = diag_nmin, diag_nmax
        psic (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          psic (nl (igk (ig))) = evc (ig, ib)
        ENDDO
        CALL invfft ('Dense', psic, dfftp)
        DO ir = 1, dfftp%nnr
          psic (ir) = psic (ir) * vxcr (ir, isk (ik))
        ENDDO
        CALL fwfft ('Dense', psic, dfftp)
        hpsi (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          hpsi (ig) = psic (nl (igk (ig)))
        ENDDO
        psic (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          psic (ig) = evc (ig, ib)
        ENDDO
#ifdef EXX
        IF (exx_is_active ()) CALL vexx (npwx, npw, 1, &
          psic, hpsi)
#endif
        dummy = (0.0D0, 0.0D0)
        DO ig = 1, npw
          dummy = dummy + conjg (psic (ig)) * hpsi (ig)
        ENDDO
        dummy = dummy * CMPLX (rytoev, 0.0D0)
        CALL mp_sum (dummy, intra_pool_comm)
        mtxeld (ib - diag_nmin + 1, ik) = dummy
      ENDDO
    ENDIF
    IF (noffdiag .GT. 0) THEN
      DO ib = offdiag_nmin, offdiag_nmax
        psic (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          psic (nl (igk (ig))) = evc (ig, ib)
        ENDDO
        CALL invfft ('Dense', psic, dfftp)
        DO ir = 1, dfftp%nnr
          psic (ir) = psic (ir) * vxcr (ir, isk (ik))
        ENDDO
        CALL fwfft ('Dense', psic, dfftp)
        hpsi (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          hpsi (ig) = psic (nl (igk (ig)))
        ENDDO
        psic (:) = (0.0D0, 0.0D0)
        DO ig = 1, npw
          psic (ig) = evc (ig, ib)
        ENDDO
#ifdef EXX
        IF (exx_is_active ()) CALL vexx (npwx, npw, 1, &
          psic, hpsi)
#endif
        DO ib2 = offdiag_nmin, offdiag_nmax
          psic2 (:) = (0.0D0, 0.0D0)
          DO ig = 1, npw
            psic2 (ig) = evc (ig, ib2)
          ENDDO
          dummy = (0.0D0, 0.0D0)
          DO ig = 1, npw
            dummy = dummy + conjg (psic2 (ig)) * hpsi (ig)
          ENDDO
          dummy = dummy * CMPLX (rytoev, 0.0D0)
          CALL mp_sum (dummy, intra_pool_comm)
          mtxelo (ib2 - offdiag_nmin + 1, ib - offdiag_nmin &
            + 1, ik) = dummy
        ENDDO
      ENDDO
    ENDIF
  ENDDO

#ifdef EXX
  IF (exx_flag) CALL stop_exx ()
#endif

  DEALLOCATE (vxcr)
  IF (noffdiag .GT. 0) DEALLOCATE (psic2)
  DEALLOCATE (hpsi)

  IF (ndiag .GT. 0) CALL mp_sum (mtxeld, inter_pool_comm)
  IF (noffdiag .GT. 0) CALL mp_sum (mtxelo, inter_pool_comm)

  CALL cryst_to_cart (nkstot, xk, at, -1)

  IF (ionode) THEN
    OPEN (unit = u, file = TRIM (output_file_name), &
      form = 'formatted', status = 'replace')
    DO ik = 1, nkstot / nspin
      WRITE (u, 101) xk(:, ik), nspin * ndiag, &
        nspin * noffdiag **2
      DO is = 1, nspin
        IF (ndiag .GT. 0) THEN
          DO ib = diag_nmin, diag_nmax
            WRITE (u, 102) is, ib, mtxeld &
              (ib - diag_nmin + 1, ik + (is - 1) * nkstot / nspin)
          ENDDO
        ENDIF
        IF (noffdiag .GT. 0) THEN
          DO ib = offdiag_nmin, offdiag_nmax
            DO ib2 = offdiag_nmin, offdiag_nmax
              WRITE (u, 103) is, ib2, ib, mtxelo &
                (ib2 - offdiag_nmin + 1, ib - offdiag_nmin + 1, &
                ik + (is - 1) * nkstot / nspin)
            ENDDO
          ENDDO
        ENDIF
      ENDDO
    ENDDO
    CLOSE (unit = u, status = 'keep')
  ENDIF

  CALL cryst_to_cart (nkstot, xk, bg, 1)

  IF (ndiag .GT. 0) DEALLOCATE (mtxeld)
  IF (noffdiag .GT. 0) DEALLOCATE (mtxelo)

  RETURN

  101 FORMAT (3F13.9, 2I8)
  102 FORMAT (2I8, 2F15.9)
  103 FORMAT (3I8, 2F15.9)

END SUBROUTINE write_vxc_g

!-------------------------------------------------------------------------------

SUBROUTINE write_vnlg (output_file_name, symm_type, wfng_kgrid, &
  wfng_nk1, wfng_nk2, wfng_nk3, wfng_dk1, wfng_dk2, wfng_dk3)

  USE cell_base, ONLY : omega, alat, tpiba, tpiba2, at, bg, ibrav
  USE constants, ONLY : pi, tpi, eps6
  USE fft_base, ONLY : dfftp
  USE gvect, ONLY : ngm, ngm_g, ig_l2g, g, mill, ecutrho
  USE io_global, ONLY : ionode, ionode_id
  USE ions_base, ONLY : nat, atm, ityp, tau, nsp
  USE kinds, ONLY : DP
  USE klist, ONLY : xk, wk, ngk, nks, nkstot
  USE lsda_mod, ONLY : nspin, isk
  USE mp, ONLY : mp_sum, mp_max, mp_get, mp_barrier
  USE mp_global, ONLY : mpime, nproc, world_comm, kunit, me_pool, &
    root_pool, my_pool_id, npool, nproc_pool, intra_pool_comm
  USE mp_wave, ONLY : mergewf
  USE start_k, ONLY : nk1, nk2, nk3, k1, k2, k3
  USE symm_base, ONLY : s, ftau, nsym
  USE uspp, ONLY : nkb, vkb, deeq
  USE uspp_param, ONLY : nhm, nh
  USE wvfct, ONLY : npwx, npw, g2kin, ecutwfc

  IMPLICIT NONE

  character (len = 256), intent (in) :: output_file_name
  character ( len = 9 ), intent (in) :: symm_type
  logical, intent (in) :: wfng_kgrid
  integer, intent (in) :: wfng_nk1
  integer, intent (in) :: wfng_nk2
  integer, intent (in) :: wfng_nk3
  real (DP), intent (in) :: wfng_dk1
  real (DP), intent (in) :: wfng_dk2
  real (DP), intent (in) :: wfng_dk3

  character :: cdate*9, ctime*9, sdate*32, stime*32, stitle*32
  integer :: i, j, k, ierr, ik, is, ig, ikb, iat, isp, ih, jh, &
    u, nkbl, nkl, nkr, iks, ike, npw_g, npwx_g, ngg, ipsour, &
    igwx, local_pw, id, nd, ntran, cell_symmetry, nrecord
  real (DP) :: alat2, recvol, dr1, t1 ( 3 ), t2 ( 3 )
  real (DP) :: r1 ( 3, 3 ), r2 ( 3, 3 ), adot ( 3, 3 )
  real (DP) :: bdot ( 3, 3 ), translation ( 3, 48 )
  integer, allocatable :: kmap ( : )
  integer, allocatable :: smap ( : )
  integer, allocatable :: gvec ( :, : )
  integer, allocatable :: ngk_g ( : )
  integer, allocatable :: igk_l2g ( :, : )
  integer, allocatable :: itmp ( : )
  integer, allocatable :: igwk ( : )
  integer, allocatable :: igwf_l2g ( : )
  integer, allocatable :: ipmask ( : )
  complex (DP), allocatable :: vkb_g ( : )

  INTEGER, EXTERNAL :: atomic_number

  IF ( nkb == 0 ) RETURN

  CALL date_and_tim ( cdate, ctime )
  WRITE ( sdate, '(A2,"-",A3,"-",A4,21X)' ) cdate(1:2), cdate(3:5), cdate(6:9)
  WRITE ( stime, '(A8,24X)' ) ctime(1:8)
  WRITE ( stitle, '("VKB-Complex",21X)' )

  u = 4
  nrecord = 1
  nd = 3

  nkbl = nkstot / kunit
  nkl = kunit * ( nkbl / npool )
  nkr = ( nkstot - nkl * npool ) / kunit
  IF ( my_pool_id .LT. nkr ) nkl = nkl + kunit
  iks = nkl * my_pool_id + 1
  IF ( my_pool_id .GE. nkr ) iks = iks + nkr * kunit
  ike = iks + nkl - 1

  ierr = 0
  IF ( ibrav .EQ. 0 ) THEN
    IF ( TRIM ( symm_type ) .EQ. 'cubic' ) THEN
      cell_symmetry = 0
    ELSEIF ( TRIM ( symm_type ) .EQ. 'hexagonal' ) THEN
      cell_symmetry = 1
    ELSE
      ierr = 1
    ENDIF
  ELSEIF ( abs ( ibrav ) .GE. 1 .AND. abs ( ibrav ) .LE. 3 ) THEN
    cell_symmetry = 0
  ELSEIF ( abs ( ibrav ) .GE. 4 .AND. abs ( ibrav ) .LE. 5 ) THEN
    cell_symmetry = 1
  ELSEIF ( abs ( ibrav ) .GE. 6 .AND. abs ( ibrav ) .LE. 14 ) THEN
    cell_symmetry = 0
  ELSE
    ierr = 1
  ENDIF
  IF ( ierr .GT. 0 ) &
    CALL errore ( 'write_vnlg', 'cell_symmetry', ierr )

  ntran = nsym
  DO i = 1, ntran
    DO j = 1, nd
      DO k = 1, nd
        r1 ( k, j ) = dble ( s ( k, j, i ) )
      ENDDO
    ENDDO
    CALL invmat ( 3, r1, r2, dr1 )
    t1 ( 1 ) = dble ( ftau ( 1, i ) ) / dble ( dfftp%nr1 )
    t1 ( 2 ) = dble ( ftau ( 2, i ) ) / dble ( dfftp%nr2 )
    t1 ( 3 ) = dble ( ftau ( 3, i ) ) / dble ( dfftp%nr3 )
    DO j = 1, nd
      t2 ( j ) = 0.0D0
      DO k = 1, nd
        t2 ( j ) = t2 ( j ) + r2 ( k, j ) * t1 ( k )
      ENDDO
      IF ( t2 ( j ) .GE. eps6 + 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) + 0.5D0 ) )
      IF ( t2 ( j ) .LT. eps6 - 0.5D0 ) &
        t2 ( j ) = t2 ( j ) - dble ( int ( t2 ( j ) - 0.5D0 ) )
    ENDDO
    DO j = 1, nd
      translation ( j, i ) = t2 ( j ) * tpi
    ENDDO
  ENDDO

  alat2 = alat ** 2
  recvol = 8.0D0 * pi**3 / omega

  DO i = 1, nd
    DO j = 1, nd
      adot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        adot ( j, i ) = adot ( j, i ) + &
          at ( k, j ) * at ( k, i ) * alat2
      ENDDO
    ENDDO
  ENDDO

  DO i = 1, nd
    DO j = 1, nd
      bdot ( j, i ) = 0.0D0
    ENDDO
  ENDDO
  DO i = 1, nd
    DO j = 1, nd
      DO k = 1, nd
        bdot ( j, i ) = bdot ( j, i ) + &
          bg ( k, j ) * bg ( k, i ) * tpiba2
      ENDDO
    ENDDO
  ENDDO

  ALLOCATE ( kmap ( nkstot ) )
  ALLOCATE ( smap ( nkstot ) )

  DO i = 1, nkstot
    j = ( i - 1 ) / nspin
    k = i - 1 - j * nspin
    kmap ( i ) = j + k * ( nkstot / nspin ) + 1
    smap ( i ) = k + 1
  ENDDO
  ierr = 0
  DO i = 1, nkstot
    ik = kmap ( i )
    is = smap ( i )
    IF ( ik .GE. iks .AND. ik .LE. ike .AND. is .NE. isk ( ik ) ) &
      ierr = ierr + 1
  ENDDO
  CALL mp_max ( ierr )
  IF ( ierr .GT. 0 ) &
    CALL errore ( 'write_vnlg', 'smap', ierr )

  ALLOCATE ( gvec ( 3, ngm_g ) )
  gvec = 0
  DO ig = 1, ngm
    gvec ( 1, ig_l2g ( ig ) ) = mill ( 1, ig )
    gvec ( 2, ig_l2g ( ig ) ) = mill ( 2, ig )
    gvec ( 3, ig_l2g ( ig ) ) = mill ( 3, ig )
  ENDDO
  CALL mp_sum ( gvec, intra_pool_comm )

  ALLOCATE ( ngk_g ( nkstot ) )
  ALLOCATE ( igk_l2g ( npwx, nks ) )
  ngk_g = 0
  igk_l2g = 0
  ALLOCATE ( itmp ( npwx ) )
  DO ik = 1, nks
    itmp = 0
    npw = npwx
    CALL gk_sort ( xk ( 1, ik + iks - 1 ), ngm, g, ecutwfc / tpiba2, &
      npw, itmp ( 1 ), g2kin )
    DO ig = 1, npw
      igk_l2g ( ig, ik ) = ig_l2g ( itmp ( ig ) )
    ENDDO
    ngk ( ik ) = npw
  ENDDO
  DEALLOCATE ( itmp )
  DO ik = 1, nks
    ngk_g ( ik + iks - 1 ) = ngk ( ik )
  ENDDO
  CALL mp_sum ( ngk_g )
  npw_g = MAXVAL ( igk_l2g ( :, : ) )
  CALL mp_max ( npw_g )
  npwx_g = MAXVAL ( ngk_g ( : ) )

  IF (ionode) THEN
    OPEN (unit = u, file = TRIM (output_file_name), &
      form = 'unformatted', status = 'replace')
    WRITE ( u ) stitle, sdate, stime
    WRITE ( u ) nspin, ngm_g, ntran, cell_symmetry, nat, ecutrho, &
      nkstot / nspin, nsp, nkb, nhm, npwx_g, ecutwfc
    IF ( wfng_kgrid ) THEN
      WRITE ( u ) dfftp%nr1, dfftp%nr2, dfftp%nr3, wfng_nk1, wfng_nk2, wfng_nk3, &
        wfng_dk1, wfng_dk2, wfng_dk3
    ELSE
      WRITE ( u ) dfftp%nr1, dfftp%nr2, dfftp%nr3, nk1, nk2, nk3, &
        0.5D0 * dble ( k1 ), 0.5D0 * dble ( k2 ), 0.5D0 * dble ( k3 )
    ENDIF
    WRITE ( u ) omega, alat, ( ( at ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( adot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) recvol, tpiba, ( ( bg ( j, i ), j = 1, nd ), i = 1, nd ), &
      ( ( bdot ( j, i ), j = 1, nd ), i = 1, nd )
    WRITE ( u ) ( ( ( s ( k, j, i ), k = 1, nd ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( translation ( j, i ), j = 1, nd ), i = 1, ntran )
    WRITE ( u ) ( ( tau ( j, i ), j = 1, nd ), atomic_number ( atm ( ityp ( i ) ) ), i = 1, nat )
    WRITE ( u ) ( ngk_g ( ik ), ik = 1, nkstot / nspin )
    WRITE ( u ) ( wk ( ik ) * dble ( nspin ) / 2.0D0, ik = 1, nkstot / nspin )
    WRITE ( u ) ( ( xk ( id, ik ), id = 1, nd ), ik = 1, nkstot / nspin )
    WRITE ( u ) ( ityp ( iat ), iat = 1, nat )
    WRITE ( u ) ( nh ( isp ), isp = 1, nsp )
    WRITE ( u ) ( ( ( ( deeq ( jh, ih, iat, is ), &
      jh = 1, nhm ), ih = 1, nhm ), iat = 1, nat ), is = 1, nspin )
    WRITE ( u ) nrecord
    WRITE ( u ) ngm_g
    WRITE ( u ) ( ( gvec ( id, ig ), id = 1, nd ), ig = 1, ngm_g )
  ENDIF

  ALLOCATE ( igwk ( npwx_g ) )

  DO i = 1, nkstot

    ik = kmap ( i )
    is = smap ( i )

    igwk = 0

    ALLOCATE ( itmp ( npw_g ) )
    itmp = 0
    IF ( ik .GE. iks .AND. ik .LE. ike ) THEN
      DO ig = 1, ngk ( ik - iks + 1 )
        itmp ( igk_l2g ( ig, ik - iks + 1 ) ) = igk_l2g ( ig, ik - iks + 1 )
      ENDDO
    ENDIF
    CALL mp_sum ( itmp )
    ngg = 0
    DO ig = 1, npw_g
      IF ( itmp ( ig ) .EQ. ig ) THEN
        ngg = ngg + 1
        igwk ( ngg ) = ig
      ENDIF
    ENDDO
    DEALLOCATE ( itmp )

    IF ( ionode ) THEN
      IF ( is .EQ. 1 ) THEN
        WRITE ( u ) nrecord
        WRITE ( u ) ngk_g ( ik )
        WRITE ( u ) ( ( gvec ( j, igwk ( ig ) ), j = 1, 3 ), &
          ig = 1, ngk_g ( ik ) )
      ENDIF
    ENDIF

    local_pw = 0
    IF ( ik .GE. iks .AND. ik .LE. ike ) THEN
      ALLOCATE ( itmp ( npwx ) )
      npw = npwx
      CALL gk_sort ( xk ( 1, ik ), ngm, g, ecutwfc / tpiba2, &
        npw, itmp ( 1 ), g2kin )
      CALL init_us_2 ( npw, itmp, xk ( 1, ik ), vkb )
      local_pw = ngk ( ik - iks + 1 )
      DEALLOCATE ( itmp )
    ENDIF

    ALLOCATE ( igwf_l2g ( local_pw ) )
    igwf_l2g = 0
    DO ig = 1, local_pw
      ngg = igk_l2g ( ig, ik - iks + 1 )
      DO j = 1, ngk_g ( ik )
        IF ( ngg .EQ. igwk ( j ) ) THEN
          igwf_l2g ( ig ) = j
          EXIT
        ENDIF
      ENDDO
    ENDDO

    ALLOCATE ( ipmask ( nproc ) )
    ipmask = 0
    ipsour = ionode_id
    IF ( npool .GT. 1 ) THEN
      IF ( ( ik .GE. iks ) .AND. ( ik .LE. ike ) ) THEN
        IF ( me_pool .EQ. root_pool ) ipmask ( mpime + 1 ) = 1
      ENDIF
      CALL mp_sum ( ipmask )
      DO j = 1, nproc
        IF ( ipmask ( j ) .EQ. 1 ) ipsour = j - 1
      ENDDO
    ENDIF
    DEALLOCATE ( ipmask )

    igwx = 0
    ierr = 0
    IF ( ik .GE. iks .AND. ik .LE. ike ) &
      igwx = MAXVAL ( igwf_l2g ( 1 : local_pw ) )
    CALL mp_max ( igwx, intra_pool_comm )
    IF ( ipsour .NE. ionode_id ) &
      CALL mp_get ( igwx, igwx, mpime, ionode_id, ipsour, 1 )
    ierr = 0
    IF ( ik .GE. iks .AND. ik .LE. ike .AND. igwx .NE. ngk_g ( ik ) ) &
      ierr = 1
    CALL mp_max ( ierr )
    IF ( ierr .GT. 0 ) &
      CALL errore ( 'write_vnlg', 'igwx ngk_g', ierr )

    ALLOCATE ( vkb_g ( MAX ( 1, igwx ) ) )

    DO ikb = 1, nkb

      vkb_g = ( 0.0D0, 0.0D0 )
      IF ( npool .GT. 1 ) THEN
        IF ( ( ik .GE. iks ) .AND. ( ik .LE. ike ) ) THEN
          CALL mergewf ( vkb ( :, ikb ), vkb_g, local_pw, igwf_l2g, &
            me_pool, nproc_pool, root_pool, intra_pool_comm )
        ENDIF
        IF ( ipsour .NE. ionode_id ) THEN
          CALL mp_get ( vkb_g, vkb_g, mpime, ionode_id, ipsour, ikb, &
            world_comm )
        ENDIF
      ELSE
        CALL mergewf ( vkb ( :, ikb ), vkb_g, local_pw, igwf_l2g, &
          mpime, nproc, ionode_id, world_comm )
      ENDIF

      IF ( ionode ) THEN
        WRITE ( u ) nrecord
        WRITE ( u ) igwx
        WRITE ( u ) ( vkb_g ( ig ), ig = 1, igwx )
      ENDIF

    ENDDO

    DEALLOCATE ( vkb_g )
    DEALLOCATE ( igwf_l2g )

  ENDDO

  IF ( ionode ) THEN
    CLOSE ( unit = u, status = 'keep' )
  ENDIF

  DEALLOCATE ( igwk )
  DEALLOCATE ( igk_l2g )
  DEALLOCATE ( ngk_g )
  DEALLOCATE ( gvec )
  DEALLOCATE ( smap )
  DEALLOCATE ( kmap )

  RETURN

END SUBROUTINE write_vnlg

!-------------------------------------------------------------------------------

subroutine check_inversion(real_or_complex, ntran, mtrx, nspin, warn, real_need_inv)

! check_inversion    Originally By D. Strubbe    Last Modified 10/14/2010
! Check whether our choice of real/complex version is appropriate given the
! presence or absence of inversion symmetry.

  USE io_global, ONLY : ionode

  implicit none

  integer, intent(in) :: real_or_complex
  integer, intent(in) :: ntran
  integer, intent(in) :: mtrx(3, 3, 48)
  integer, intent(in) :: nspin
  logical, intent(in) :: warn ! set to false to suppress warnings, for converters
  logical, intent(in) :: real_need_inv ! use for generating routines to block real without inversion

  integer :: invflag, isym, ii, jj, itest

  invflag = 0
  do isym = 1, ntran
    itest = 0
    do ii = 1, 3
      do jj = 1, 3
        if(ii .eq. jj) then
          itest = itest + (mtrx(ii, jj, isym) + 1)**2
        else
          itest = itest + mtrx(ii, jj, isym)**2
        endif
      enddo
    enddo
    if(itest .eq. 0) invflag = invflag + 1
    if(invflag .gt. 1) call errore('check_inversion', 'More than one inversion symmetry operation is present.', invflag)
  enddo

  if(real_or_complex .eq. 2) then
    if(invflag .ne. 0 .and. warn) then
      if(ionode) write(6, '(a)') 'WARNING: Inversion symmetry is present. The real version would be faster.'
    endif
  else
    if(invflag .eq. 0) then
      if(real_need_inv) then
        call errore('check_inversion', 'The real version cannot be used without inversion symmetry.', -1)
      endif
      if(ionode) then
        write(6, '(a)') 'WARNING: Inversion symmetry is absent in symmetries used to reduce k-grid.'
        write(6, '(a)') 'Be sure inversion is still a spatial symmetry, or you must use complex version instead.'
      endif
    endif
    if(nspin .eq. 2) then
      call errore('check_inversion', &
        'Time-reversal symmetry is absent in spin-polarized calculation. Complex version must be used.', -2)
    endif
  endif

  return

end subroutine check_inversion

!-------------------------------------------------------------------------------
