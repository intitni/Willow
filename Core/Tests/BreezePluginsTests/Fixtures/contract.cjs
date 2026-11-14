// Original offline contract fixture. No third-party content or credentials.
const uuid = '12345678-1234-4234-8234-123456789abc';
let coverRequests = 0;
const comic = {metadata:[{type:'other',name:'其他信息',value:[{name:'状态：连载中'},{name:'语言：中文'}]},{type:'author',name:'作者',value:[{name:'Test Author',onTap:{type:'openSearch',payload:{keyword:'Test Author',extern:{author:'Test Author'}}}}]},{type:'tags',name:'标签',value:[{name:'Adventure'},{name:'Fantasy'}]}],titleMeta:[{name:'页数：123'},{name:'更新时间：2026-11-14T01:00:00Z'}],id:'comic/1',title:'Contract Comic',description:'Offline test',creator:{name:'Willow'},cover:{url:'https://example.invalid/cover.png',extern:{token:'cover'}}};
module.exports = {
  getInfo: () => ({uuid, name:'Contract Source',version:'1.0.0',haveCloudFavorite:true,functions:[{id:'ranking',title:'排行榜'},{id:'hot',title:'热搜',action:{type:'openSearch',payload:{keyword:'Hot'}}}]}),
  init: () => ({data:{ok:true}}),
  getPluginHomePagesBundle: () => ({data:{tabs:[
    {id:'latest',title:'Latest',scene:{body:{request:{fnPath:'feed',core:{},extern:{}}}}},
    {id:'hot',title:'Hot searches',page:{scheme:{body:{type:'chip-list',key:'terms'}},data:{terms:[{label:'Adventure',action:{type:'openSearch',payload:{keyword:'Adventure',extern:{category:'fiction'}}}}]}}},
    {id:'navigation',title:'Navigation',header:{actions:[{title:'Favorites',action:{type:'openCloudFavorite',payload:{}}}]},page:{scheme:{body:{type:'list',children:[{type:'action-grid',key:'links'},{type:'comic-section-list',key:'sections'}]}},data:{links:[{title:'Ranking',action:{type:'openPluginFunction',payload:{id:'ranking',title:'Ranking'}}}],sections:[{title:'Recommended',items:[comic]}]}}},
    {id:'ranking',title:'Ranking',scene:{body:{request:{fnPath:'rankFeed',core:{kind:'weekly'},extern:{scope:'rank'}}},filter:{fnPath:'rankFilter'}}}
  ]}}),
  rankFilter: () => ({scheme:{fields:[{key:'order',kind:'choice',options:[{value:'popular',label:'Popular',result:{core:{sort:'popular'},extern:{period:'week'}}}]}]},data:{values:{order:'popular'}}}),
  rankFeed: ({page,kind,sort,extern}) => {
    if(kind!=='weekly'||sort!=='popular'||extern.scope!=='rank'||extern.period!=='week') throw Error('Ranking filters lost');
    return {data:{items:[{...comic,id:'rank/'+page}],paging:{hasReachedMax:page>=2}}};
  },
  getFunctionPage: ({id}) => {
    if(id!=='ranking') throw Error('Wrong function page');
    return {scheme:{body:{type:'comic-grid',key:'comics'}},data:{comics:[comic]}};
  },
  feed: () => ({data:{items:[comic],hasReachedMax:true}}),
  getPluginCloudFavoritePagesBundle: () => ({data:{tabs:[{
    id:'favorites',title:'Favorites',scene:{
      body:{request:{fnPath:'favoriteFeed',core:{},extern:{scope:'favorite'}}},
      filter:{fnPath:'favoriteFilter',extern:{scope:'favorite'}}
    }
  }]}}),
  favoriteFilter: ({extern}) => {
    if (extern.scope !== 'favorite') throw Error('Favorite filter context lost');
    return {scheme:{fields:[{key:'folder',kind:'choice',options:[
      {value:'a',label:'First',result:{extern:{folder:'a'}}},
      {value:'b',label:'Second',result:{core:{order:'latest'},extern:{folder:'b'}}}
    ]}]},data:{values:{folder:'b'}}};
  },
  favoriteFeed: ({page,order,extern}) => {
    if (page !== 1 || order !== 'latest' || extern.folder !== 'b' || extern.scope !== 'favorite') {
      throw Error('Favorite filters not forwarded');
    }
    return {data:{items:[comic],hasReachedMax:true}};
  },
  getAdvancedSearchScheme: () => ({
    scheme:{fields:[
      {key:'keywordExtra',kind:'text',label:'Extra'},
      {key:'isExact',kind:'switch',label:'Exact'},
      {key:'sort',kind:'choice',label:'Sort',options:[{value:1,label:'Newest'}]},
      {key:'genres',kind:'multiChoice',label:'Genres',options:[{value:'adventure',label:'Adventure'}]}
    ]},
    data:{values:{keywordExtra:'example',isExact:true,sort:1,genres:['adventure']}}
  }),
  searchComic: ({keyword,page,extern}) => {
    if (keyword === 'Advanced' && (extern.keywordExtra !== 'example' || !extern.isExact ||
        extern.sort !== 1 || extern.genres[0] !== 'adventure')) throw Error('Advanced filters not forwarded');
    return {data:{items:['Contract','Advanced'].includes(keyword)?[comic]:[],paging:{page,pages:1,hasReachedMax:true}}};
  },
  getComicDetail: ({comicId}) => ({data:{normal:{comicInfo:comic,totalLikes:1234,totalComments:56,allowCollected:true,allowLike:true,allowComments:true,isLiked:false,isFavourite:false,eps:[{id:'logical/1',requestId:'request/1',name:'Chapter 1',order:1,extern:{token:'chapter'}},{id:'logical/2',requestId:'request/2',name:'Chapter 2',order:2,extern:{token:'chapter2'}}]}}}),
  toggleLike: ({comicId,currentLiked}) => {
    if (comicId !== comic.id) throw Error('Comic identity lost');
    return {data:{liked:!currentLiked}};
  },
  startFavoriteAction: ({comicId,action,currentFavorite}) => {
    if (comicId !== comic.id || action !== 'add' || currentFavorite) throw Error('Favorite action lost');
    return {data:{status:'awaitingInput',continuationToken:'offline-token',input:{
      type:'select',key:'folder',options:[{id:'b',label:'Second'}]
    }}};
  },
  continueFavoriteAction: ({comicId,action,continuationToken,input}) => {
    if (comicId !== comic.id || action !== 'add' || continuationToken !== 'offline-token' ||
        input.key !== 'folder' || input.value !== 'b') throw Error('Favorite continuation lost');
    return {data:{status:'completed',favorited:true,committed:true}};
  },
  getCommentFeed: ({comicId,page}) => {
    if (comicId !== comic.id || page !== 1) throw Error('Comment page invalid');
    return {data:{topItems:[{id:'top',author:{name:'Pinned'},content:'Pinned comment'}],
      items:[{id:'c1',author:{name:'Reader'},content:'A comment',replyCount:1,extern:{token:'reply'}}],
      paging:{hasReachedMax:true},replyMode:'lazy',canComment:{comic:true,reply:true}}};
  },
  loadCommentReplies: ({comicId,commentId,page,extern}) => {
    if (comicId !== comic.id || commentId !== 'c1' || page !== 1 || extern.token !== 'reply') {
      throw Error('Reply context lost');
    }
    return {data:{items:[{id:'r1',author:{name:'Reader'},content:'A reply'}],paging:{hasReachedMax:true}}};
  },
  postComment: ({comicId,content}) => {
    if (comicId !== comic.id || content !== 'Offline comment') throw Error('Comment payload invalid');
    return {data:{insertHint:{needsRefetch:true}}};
  },
  postCommentReply: ({comicId,commentId,content,extern}) => {
    if (comicId !== comic.id || commentId !== 'c1' || content !== 'Offline reply' || extern.token !== 'reply') {
      throw Error('Reply payload invalid');
    }
    return {data:{insertHint:{needsRefetch:true}}};
  },
  getReadSnapshot: ({chapterId,extern}) => {
    if (!((chapterId === 'request/1' && extern.token === 'chapter') || (chapterId === 'request/2' && extern.token === 'chapter2'))) throw Error('Chapter metadata lost');
    return {data:{chapter:{pages:[{id:'1',url:'https://example.invalid/page.png',extern:{token:'page'}}]}}};
  },
  coverRequestCount: () => coverRequests,
  fetchImageBytes: async ({extern}) => {
    if (!['page','cover'].includes(extern.token)) throw Error('Image metadata lost');
    if (extern.token === 'cover') {
      coverRequests += 1;
      await new Promise(resolve => setTimeout(resolve, 30));
      return new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31, 0, 3, 3, 2, 0, 239, 163, 69, 153, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]);
    }
    return new Uint8Array([137,80,78,71,13,10,26,10]);
  },
  getSettingsBundle: () => ({scheme:{sections:[{fields:[{key:'account',label:'Account',kind:'text',fnPath:'saveSettings'}]}]},data:{values:{account:''},canLogin:true}}),
  saveSettings: async ({key,value}) => bridge.call('save_plugin_config',key,JSON.stringify(value)),
  getLoginBundle: () => ({scheme:{title:'Login',fields:[],action:{fnPath:'login',submitText:'Login'}},data:{values:{}}}),
  login: async () => {
    const raw=await bridge.call('load_plugin_config','account','');
    if(JSON.parse(raw).value!=='reader') throw Error('Settings not persisted');
    return {data:{ok:true}};
  }
};
