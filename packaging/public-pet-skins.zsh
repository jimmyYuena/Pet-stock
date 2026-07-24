#!/bin/zsh

# Public pet packs supplied by the project owner as commercially usable
# derivative artwork. Keep this list aligned with PetAppearance.availableCases.
typeset -ga PUBLIC_PET_SKINS=(
  mech
  polar
  gptniang
  pikachu
  gian
  suneo
  shizuka
  shinchan
  maruko
  atom
  sailormoon
  kagome
  kaitokid
  heimerdinger
  yantianzong
  cubaibai
  sakiko
  nimbus
  yamada
)

copy_public_pet_skins() {
  local source_dir="$1"
  local destination_dir="$2"
  local prefix

  for prefix in "${PUBLIC_PET_SKINS[@]}"; do
    local -a frames=("$source_dir"/skin_"${prefix}"_*.png(N))
    if (( ${#frames[@]} == 0 )); then
      echo "公开宠物素材缺失: skin_${prefix}_*.png" >&2
      return 1
    fi
    cp "${frames[@]}" "$destination_dir/"
  done
}
