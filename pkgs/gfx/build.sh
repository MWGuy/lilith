_download() {
    if [[ ! -f "$2" ]]; then
        wget -O"$2" "$1"
    fi
}

build() {
    _download https://raw.githubusercontent.com/nothings/stb/master/stb_image.h "$build_dir/stb_image.h"
    _download https://upload.wikimedia.org/wikipedia/en/7/7d/Lenna_%28test_image%29.png "$build_dir/test.png"
    
    for i in $script_dir/*.c; do
        ${opt_arch}-gcc -g -o $build_dir/$(basename $i .c) $i -lm
    done
}

install() {
    for i in $script_dir/*.c; do
        sudo cp $build_dir/$(basename $i .c) $install_dir/bin
    done
    sudo cp $build_dir/test.png $install_dir/test.png
}