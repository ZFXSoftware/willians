import { createClient } from "@supabase/supabase-js"

const supabaseUrl = "https://imdmqnvdvzbzkcjzlwoh.supabase.co"
const supabaseKey = "sb_publishable_w-o07DPY_pAGs2xsOyBhDA_WUrAtaIg"

export const supabase = createClient(supabaseUrl, supabaseKey)