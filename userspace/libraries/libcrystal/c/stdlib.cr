lib LibC
  fun malloc(size : SizeT) : Void*
  fun calloc(nmemb : SizeT, size : SizeT) : Void*
  fun realloc(ptr : Void*, size : SizeT) : Void*
  fun free(ptr : Void*)
end
