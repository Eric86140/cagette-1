package controller;
import sugoi.db.Cache;
import sugoi.Web;
import ufront.mail.*;
import Common;
using Lambda;

class Cron extends Controller
{

	public function doDefault() 
	{
		
	}
	
	/**
	 * CLI only en prod
	 */
	function canRun() {
		if (App.current.user != null && App.current.user.isAdmin()){
			return true;
		}else if (App.config.DEBUG) {
			return true;
		}else {
			
			if (Web.isModNeko) {
				Sys.print("only CLI.");
				return false;
			}else {
				return true;
			}
		}
	}
	
	public function doMinute() {
		if (!canRun()) return;
		
		app.event(MinutelyCron);
		
		distribNotif(4,db.User.UserFlags.HasEmailNotif4h); //4h before
		distribNotif(24,db.User.UserFlags.HasEmailNotif24h); //24h before
	}
	
	public function doHour() {
		app.event(HourlyCron);
	}
	
	
	public function doDaily() {
		if (!canRun()) return;
		
		app.event(DailyCron);
		
		//ERRORS MONITORING
		var n = Date.now();
		var yest24h = new Date(n.getFullYear(), n.getMonth(), n.getDate(), 0, 0, 0);
		var yest0h = DateTools.delta(yest24h, -1000 * 60 * 60 * 24);
		
		var errors = sugoi.db.Error.manager.search( $date < yest24h && $date > yest0h  );		
		if (errors.length > 0) {
			var report = new StringBuf();
			report.add("<h1>" + App.config.NAME + " : ERRORS</h1>");
			for (e in errors) {
				report.add("<div><pre>"+e.error + " at URL " + e.url + " ( user : " + (e.user!=null?e.user.toString():"none") + ", IP : " + e.ip + ")</pre></div><hr/>");
			}
			
			var m = new Email();
			m.from(new EmailAddress(App.config.get("default_email"),"Cagette.net"));
			m.to(new EmailAddress(App.config.get("webmaster_email")));
			m.setSubject(App.config.NAME+" Errors");
			m.setHtml( app.processTemplate("mail/message.mtt", { text:report.toString() } ) );
			App.getMailer().send(m);
		}
		
	}
	
	/**
	 * Send email notifications to users before a distribution
	 * @param	hour
	 * @param	flag
	 */
	function distribNotif(hour:Int, flag:db.User.UserFlags) {
		
		//trouve les distrib qui commencent dans le nombre d'heures demandé
 		//on recherche celles qui commencent jusqu'à une heure avant pour ne pas en rater 
 		var d = DateTools.delta(Date.now(), 1000.0 * 60 * 60 * (hour-1));
 		var h = DateTools.delta(Date.now(), 1000.0 * 60 * 60 * hour);
		var distribs = db.Distribution.manager.search( $date >= d && $date <= h , false);
		
		//trace("distribNotif "+hour+" from "+d+" to "+h);
		
		//on s'arrete immédiatement si aucune distibution trouvée
 		if (distribs.length == 0) return;
		
		//cherche plus tard si on a pas une "grappe" de distrib
		while (true) {
			var extraDistribs = db.Distribution.manager.search( $date >= h && $date <DateTools.delta(h,1000.0*60*60) , false);			
			for ( e in extraDistribs) distribs.add(e);
			if (extraDistribs.length > 0) {
				//on fait un tour de plus avec une heure plus tard
				h = DateTools.delta(h, 1000.0 * 60 * 60);
			}else {
				//plus de distribs
				break;
			}
		}
		
		//on vérifie dans le cache du jour que ces distrib n'ont pas deja été traitées lors d'un cron précédent
		var cacheId = Date.now().toString().substr(0, 10)+Std.string(flag);
		var dist :Array<Int> = sugoi.db.Cache.get(cacheId);
		if (dist != null) {
			for (d in Lambda.array(distribs)) {
				if (Lambda.exists(dist, function(x) return x == d.id)) {
					distribs.remove(d);
				}
			}
		}else {
			dist = [];
		}
		
		//toutes les distribs trouvées ont deja été traitées
		if (distribs.length == 0) return;
		
		//stocke cache
		for (d in distribs) dist.push(d.id);
		Cache.set(cacheId, dist, 24 * 60 * 60);
		
		//We have now the distribs we want to notify about.
		//trace(distribs);
		var distribsByContractId = new Map<Int,db.Distribution>();
		for (d in distribs) distribsByContractId.set(d.contract.id, d);

		//Boucle sur les distributions pour gerer le cas de plusieurs distributions le même jour sur le même contrat
 		var orders = [];
 		for (d in distribs) {
 			//get orders for both type of contracts
			for ( x in d.contract.getOrders(d)) orders.push(x);
		}
		
		/*
		 * Group orders by users-amap to receive separate emails by groups for the same user.
		 * Map key is $userId-$groupId
		*/
		var users = new Map <String,{
			user:db.User,
			distrib:db.Distribution,
			products:Array<db.UserContract>			
		}>();
		
		for (o in orders) {
			
			var x = users.get(o.userId+"-"+o.product.contract.amap.id);
			if (x == null) x = {user:o.user,distrib:null,products:[]};
			x.distrib = distribsByContractId.get(o.product.contract.id);
			//x.distrib = o.distribution;
			x.products.push(o);			
			users.set(o.userId+"-"+o.product.contract.amap.id, x);
			
			// Prévenir également le deuxième user en cas des commandes alternées
 			if (o.user2 != null) {
 				var x = users.get(o.user2.id+"-"+o.product.contract.amap.id);
 				if (x == null) x = {user:o.user2,distrib:null,products:[]};
 				x.distrib = distribsByContractId.get(o.product.contract.id);
 				x.products.push(o);
 				users.set(o.user2.id+"-"+o.product.contract.amap.id, x);
 			}
		}
		
		
		for ( u in users) {
			
			if (u.user.flags.has(flag) ) {
				
				if (u.user.email != null) {
					var group = u.distrib.contract.amap.name;

					var text = "N'oubliez pas la distribution : <b>" + view.hDate(u.distrib.date) + "</b><br>";
					text += "Vos produits à récupérer :<br><ul>";
					for ( p in u.products) {
						text += "<li>"+p.quantity+" x "+p.product.name;
 						// Gerer le cas des contrats en alternance
 						if (p.user2 != null) {
 							text += " en alternance avec ";
 							if (u.user == p.user)
 								text += p.user2.getCoupleName();
 							else
 								text += p.user.getCoupleName();
 						}
 						text += "</li>";
					}
					text += "</ul>";
					
					if (u.distrib.isDistributor(u.user)) {
						text += "<b>ATTENTION : Vous ou votre conjoint(e) êtes distributeur ! N'oubliez pas d'imprimer la liste d'émargement.</b>";
					}

					var m = new Email();
					m.from(new EmailAddress(App.config.get("default_email"),"Cagette.net"));					
					m.to(new EmailAddress(u.user.email, u.user.getName()));					
					if(u.user.email2!=null) m.cc(new EmailAddress(u.user.email2));
					m.setSubject( group+" : Distribution " + app.view.hDate(u.distrib.date) );
					m.setHtml( app.processTemplate("mail/message.mtt", { text:text } ) );
					
					//debug
					Sys.print("<hr/>" + m.toList + "<br/>" + m.subject + "<br/>" + m.html + "");
					
					try {
						if (!App.config.DEBUG){
							Sys.sleep(0.25);
							App.getMailer().send(m);	
						}
						
					}catch (e:Dynamic) {
						app.logError(e);
					}
				}
			}
		}
	}
	
}
